import Foundation
import SwiftData

struct ReadingGenerationRequest: Codable, Equatable, Sendable {
    let topic: String
    let genre: String?
    let targetLanguage: String
    let translationModel: String?
    let targetWordCount: Int?
    let skill: ReadingSkill

    init(
        topic: String,
        genre: String? = nil,
        targetLanguage: String = "zh-Hans",
        translationModel: String? = nil,
        targetWordCount: Int? = nil,
        skill: ReadingSkill
    ) {
        self.topic = topic
        self.genre = genre
        self.targetLanguage = targetLanguage
        self.translationModel = translationModel
        self.targetWordCount = targetWordCount
        self.skill = skill
    }
}

enum GenerationPipelineError: LocalizedError, Equatable, Sendable {
    case missingDocument
    case missingRecoveryPayload
    case invalidRecoveryPayload
    case unsupportedStage(ProcessingStage)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .missingDocument:
            "生成任务没有关联草稿文档。"
        case .missingRecoveryPayload:
            "生成任务缺少恢复所需的数据。"
        case .invalidRecoveryPayload:
            "生成任务的恢复数据无法读取。"
        case let .unsupportedStage(stage):
            "生成任务当前不能继续：\(stage.rawValue)。"
        case .persistenceFailed:
            "无法保存生成进度。"
        }
    }
}

/// 串行执行生成阶段，并在每个有效产物写入后立即保存下一待执行阶段。
/// 调用方通过取消承载 `start`、`resume` 或 `retry` 的 Task 来停止在途模型请求。
@MainActor
final class GenerationPipeline {
    private let modelContext: ModelContext
    private let provider: any AIProvider
    private let progressHandler: ((ProcessingJob) -> Void)?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        modelContext: ModelContext,
        provider: any AIProvider,
        progressHandler: ((ProcessingJob) -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self.provider = provider
        self.progressHandler = progressHandler
    }

    /// 创建可恢复草稿并执行完整流水线。即使后续失败，返回前草稿也已经进入 Store。
    func start(_ request: ReadingGenerationRequest) async throws -> ReadingDocument {
        // 在创建草稿前完成输入校验，避免无效主题产生无法继续的本地记录。
        _ = try ArticlePromptBuilder.makeRequest(
            skill: request.skill,
            topic: request.topic,
            genre: request.genre,
            preferredWordCount: request.targetWordCount
        )
        _ = try TranslationPromptBuilder.makeRequest(
            sourceParagraphs: [.init(id: UUID(), text: "validation")],
            targetLanguage: request.targetLanguage
        )

        let payload: Data
        do {
            payload = try encoder.encode(request)
        } catch {
            throw GenerationPipelineError.invalidRecoveryPayload
        }

        let document = ReadingDocument(
            title: request.topic.trimmingCharacters(in: .whitespacesAndNewlines),
            state: .processing
        )
        document.recordGenerationSkill(request.skill)

        let job = ProcessingJob(
            stage: .generatingArticle,
            intermediatePayload: payload
        )
        document.processingJobs = [job]
        modelContext.insert(document)
        try saveContext()
        reportProgress(job)

        try await execute(job: job, request: request)
        return document
    }

    /// 继续 App 上次退出时尚在进行的阶段，不增加人工重试次数。
    func resume(_ job: ProcessingJob) async throws -> ReadingDocument {
        guard resumableActiveStages.contains(job.stage) else {
            throw GenerationPipelineError.unsupportedStage(job.stage)
        }
        let request = try recoveryRequest(for: job)
        guard let document = job.document else {
            throw GenerationPipelineError.missingDocument
        }

        document.state = .processing
        clearError(on: job)
        touch(document: document, job: job)
        try saveContext()
        reportProgress(job)
        try await execute(job: job, request: request)
        return document
    }

    /// 从失败或取消时记录的阶段继续；已经保存的更早产物不会重新生成。
    func retry(_ job: ProcessingJob) async throws -> ReadingDocument {
        guard job.stage == .failed || job.stage == .cancelled,
              let failedStage = job.failedStage,
              resumableActiveStages.contains(failedStage) else {
            throw GenerationPipelineError.unsupportedStage(job.stage)
        }
        let request = try recoveryRequest(for: job)
        guard let document = job.document else {
            throw GenerationPipelineError.missingDocument
        }

        job.retryCount += 1
        job.stage = failedStage
        job.failedStage = nil
        clearError(on: job)
        document.state = .processing
        touch(document: document, job: job)
        try saveContext()
        reportProgress(job)

        try await execute(job: job, request: request)
        return document
    }

    /// 供启动恢复界面查询；失败、取消和意外中断的生成任务都会返回。
    func resumableJobs() throws -> [ProcessingJob] {
        let jobs = try modelContext.fetch(FetchDescriptor<ProcessingJob>())
        return jobs.filter { job in
            job.stage != .completed
                && job.intermediatePayload != nil
                && job.document?.sourceType == .generated
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func execute(
        job: ProcessingJob,
        request: ReadingGenerationRequest
    ) async throws {
        guard let document = job.document else {
            throw GenerationPipelineError.missingDocument
        }

        do {
            while job.stage != .completed {
                try Task.checkCancellation()

                switch job.stage {
                case .generatingArticle:
                    try await generateArticle(for: document, job: job, request: request)
                case .generatingQuestions:
                    try await generateQuestions(for: document, job: job, request: request)
                case .translating:
                    try await translate(document: document, job: job, request: request)
                case .validating:
                    try validate(document: document, request: request)
                    document.state = .ready
                    job.stage = .completed
                    job.failedStage = nil
                    clearError(on: job)
                    touch(document: document, job: job)
                    try saveContext()
                    reportProgress(job)
                default:
                    throw GenerationPipelineError.unsupportedStage(job.stage)
                }
            }
        } catch is CancellationError {
            let cancelledStage = resumableActiveStages.contains(job.stage)
                ? job.stage
                : .validating
            job.stage = .cancelled
            job.failedStage = cancelledStage
            job.lastErrorCode = .cancelled
            job.lastError = "生成已取消。"
            document.state = .draft
            touch(document: document, job: job)
            try saveContext()
            reportProgress(job)
            throw CancellationError()
        } catch {
            let failedStage = resumableActiveStages.contains(job.stage)
                ? job.stage
                : .validating
            job.stage = .failed
            job.failedStage = failedStage
            job.lastErrorCode = errorCode(for: error)
            job.lastError = userFacingMessage(for: error)
            document.state = .failed
            touch(document: document, job: job)
            try saveContext()
            reportProgress(job)
            throw error
        }
    }

    private func generateArticle(
        for document: ReadingDocument,
        job: ProcessingJob,
        request: ReadingGenerationRequest
    ) async throws {
        let providerRequest = try ArticlePromptBuilder.makeRequest(
            skill: request.skill,
            topic: request.topic,
            genre: request.genre,
            preferredWordCount: request.targetWordCount
        )
        let article = try await provider.generateArticle(request: providerRequest)
        try Task.checkCancellation()
        try AIResponseValidator.validate(article: article, for: providerRequest)

        document.title = article.title
        document.paragraphs = article.paragraphs.enumerated().map { order, paragraph in
            Paragraph(id: UUID(), order: order, originalText: paragraph.text)
        }
        job.stage = .generatingQuestions
        touch(document: document, job: job)
        try saveContext()
        reportProgress(job)
    }

    private func generateQuestions(
        for document: ReadingDocument,
        job: ProcessingJob,
        request: ReadingGenerationRequest
    ) async throws {
        let sourceParagraphs = sourceParagraphs(for: document)
        let providerRequest = try QuestionPromptBuilder.makeRequest(
            skill: request.skill,
            sourceParagraphs: sourceParagraphs
        )
        let generatedQuestions = try await provider.generateQuestions(request: providerRequest)
        try Task.checkCancellation()
        try AIResponseValidator.validate(questions: generatedQuestions, for: providerRequest)

        document.questions = generatedQuestions.enumerated().map { order, generated in
            let optionIDs = Dictionary(
                uniqueKeysWithValues: generated.options.map { ($0.id, UUID()) }
            )
            let question = Question(
                id: UUID(),
                order: order,
                stem: generated.stem,
                correctOptionID: optionIDs[generated.correctOptionID],
                explanation: generated.explanation,
                evidenceParagraphIDs: generated.evidenceParagraphIDs
            )
            question.options = generated.options.enumerated().map { optionOrder, option in
                QuestionOption(
                    id: optionIDs[option.id] ?? UUID(),
                    order: optionOrder,
                    text: option.text
                )
            }
            return question
        }
        job.stage = .translating
        touch(document: document, job: job)
        try saveContext()
        reportProgress(job)
    }

    private func translate(
        document: ReadingDocument,
        job: ProcessingJob,
        request: ReadingGenerationRequest
    ) async throws {
        let sourceParagraphs = sourceParagraphs(for: document)
        let providerRequest = try TranslationPromptBuilder.makeRequest(
            sourceParagraphs: sourceParagraphs,
            targetLanguage: request.targetLanguage
        )
        let translations = try await provider.translateParagraphs(request: providerRequest)
        try Task.checkCancellation()
        try AIResponseValidator.validate(translations: translations, for: providerRequest)

        let translationsByID = Dictionary(
            uniqueKeysWithValues: translations.map { ($0.paragraphID, $0.translatedText) }
        )
        for paragraph in document.paragraphs {
            paragraph.translatedText = translationsByID[paragraph.id]
            paragraph.translationLanguage = request.targetLanguage
            paragraph.translationModel = request.translationModel
        }
        job.stage = .validating
        touch(document: document, job: job)
        try saveContext()
        reportProgress(job)
    }

    /// Provider 会校验单次响应；这里再从已持久化模型重建 DTO，防止阶段间映射遗漏。
    private func validate(
        document: ReadingDocument,
        request: ReadingGenerationRequest
    ) throws {
        let articleRequest = try ArticlePromptBuilder.makeRequest(
            skill: request.skill,
            topic: request.topic,
            genre: request.genre,
            preferredWordCount: request.targetWordCount
        )
        let article = GeneratedArticle(
            title: document.title,
            paragraphs: document.paragraphs
                .sorted { $0.order < $1.order }
                .map { .init(id: $0.id, text: $0.originalText) }
        )
        try AIResponseValidator.validate(article: article, for: articleRequest)

        let sources = sourceParagraphs(for: document)
        let questionRequest = try QuestionPromptBuilder.makeRequest(
            skill: request.skill,
            sourceParagraphs: sources
        )
        let questions = document.questions
            .sorted { $0.order < $1.order }
            .map { question in
                GeneratedQuestion(
                    id: question.id,
                    stem: question.stem,
                    options: question.options
                        .sorted { $0.order < $1.order }
                        .map { .init(id: $0.id, text: $0.text) },
                    correctOptionID: question.correctOptionID ?? UUID(),
                    explanation: question.explanation,
                    evidenceParagraphIDs: question.evidenceParagraphIDs
                )
            }
        try AIResponseValidator.validate(questions: questions, for: questionRequest)

        let translationRequest = try TranslationPromptBuilder.makeRequest(
            sourceParagraphs: sources,
            targetLanguage: request.targetLanguage
        )
        let translations = document.paragraphs.compactMap { paragraph in
            paragraph.translatedText.map {
                ParagraphTranslation(paragraphID: paragraph.id, translatedText: $0)
            }
        }
        try AIResponseValidator.validate(translations: translations, for: translationRequest)
    }

    private func recoveryRequest(for job: ProcessingJob) throws -> ReadingGenerationRequest {
        guard let payload = job.intermediatePayload else {
            throw GenerationPipelineError.missingRecoveryPayload
        }
        do {
            return try decoder.decode(ReadingGenerationRequest.self, from: payload)
        } catch {
            throw GenerationPipelineError.invalidRecoveryPayload
        }
    }

    private func sourceParagraphs(for document: ReadingDocument) -> [SourceParagraph] {
        document.paragraphs
            .sorted { $0.order < $1.order }
            .map { .init(id: $0.id, text: $0.originalText) }
    }

    private func touch(document: ReadingDocument, job: ProcessingJob) {
        let now = Date.now
        document.updatedAt = now
        job.updatedAt = now
    }

    private func clearError(on job: ProcessingJob) {
        job.lastErrorCode = nil
        job.lastError = nil
    }

    private func saveContext() throws {
        do {
            try modelContext.save()
        } catch {
            throw GenerationPipelineError.persistenceFailed
        }
    }

    private func reportProgress(_ job: ProcessingJob) {
        progressHandler?(job)
    }

    private func errorCode(for error: any Error) -> ProcessingErrorCode {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .invalidRequest:
                return .invalidInput
            case .timeout:
                return .timeout
            case .network:
                return .network
            case .invalidAPIKey:
                return .invalidAPIKey
            case .modelNotFound:
                return .modelNotFound
            case .rateLimited:
                return .rateLimited
            case .server, .invalidHTTPResponse, .invalidProviderResponse, .emptyResponse:
                return .provider
            case .outputDecodingFailed:
                return .invalidOutput
            case .validationFailed:
                return .validation
            }
        }
        if error is ReadingPromptBuilderError {
            return .invalidInput
        }
        if let pipelineError = error as? GenerationPipelineError {
            switch pipelineError {
            case .persistenceFailed:
                return .persistence
            case .missingDocument, .missingRecoveryPayload,
                 .invalidRecoveryPayload, .unsupportedStage:
                return .invalidState
            }
        }
        return .unknown
    }

    private func userFacingMessage(for error: any Error) -> String {
        if let providerError = error as? AIProviderError {
            return providerError.errorDescription ?? "模型请求失败。"
        }
        if let promptError = error as? ReadingPromptBuilderError {
            return promptError.errorDescription ?? "生成输入无效。"
        }
        if let pipelineError = error as? GenerationPipelineError {
            return pipelineError.errorDescription ?? "生成状态无效。"
        }
        return "生成过程发生未知错误。"
    }

    private var resumableActiveStages: Set<ProcessingStage> {
        [.generatingArticle, .generatingQuestions, .translating, .validating]
    }
}
