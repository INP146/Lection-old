import Foundation
import SwiftData
import Testing
@testable import Lection

@Suite("Generation pipeline", .serialized)
@MainActor
struct GenerationPipelineTests {
    @Test("Successful generation persists every product and marks the document ready")
    func successfulGeneration() async throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let fixtures = makeFixtures()
        let provider = PipelineTestProvider(fixtures: fixtures)
        var observedStages: [ProcessingStage] = []
        let pipeline = GenerationPipeline(
            modelContext: container.mainContext,
            provider: provider,
            progressHandler: { observedStages.append($0.stage) }
        )

        let document = try await pipeline.start(makeRequest())
        let job = try #require(document.processingJobs.first)

        #expect(document.title == fixtures.article.title)
        #expect(document.state == .ready)
        #expect(document.skillID == "general-english-reading")
        #expect(document.skillVersion == 1)
        #expect(document.paragraphs.count == 5)
        #expect(document.paragraphs.allSatisfy {
            $0.translatedText?.isEmpty == false
                && $0.translationLanguage == "zh-Hans"
                && $0.translationModel == "test-model"
        })
        #expect(document.questions.count == 5)
        #expect(document.questions.allSatisfy { $0.options.count == 4 })
        #expect(job.stage == .completed)
        #expect(job.retryCount == 0)
        #expect(job.lastErrorCode == nil)
        #expect(try pipeline.resumableJobs().isEmpty)
        #expect(observedStages == [
            .generatingArticle,
            .generatingQuestions,
            .translating,
            .validating,
            .completed,
        ])
        #expect(await provider.callCounts() == .init(article: 1, questions: 1, translation: 1))
    }

    @Test("Repeated provider IDs cannot merge content across documents")
    func repeatedProviderIDsStayDocumentScoped() async throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let provider = PipelineTestProvider(fixtures: makeFixtures())
        let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)

        let first = try await pipeline.start(makeRequest())
        let firstParagraphIDs = Set(first.paragraphs.map(\.id))
        let firstQuestionIDs = Set(first.questions.map(\.id))
        let firstOptionIDs = Set(first.questions.flatMap(\.options).map(\.id))

        let second = try await pipeline.start(makeRequest())

        #expect(try container.mainContext.fetchCount(FetchDescriptor<ReadingDocument>()) == 2)
        #expect(first.paragraphs.count == 5)
        #expect(first.questions.count == 5)
        #expect(second.paragraphs.count == 5)
        #expect(second.questions.count == 5)
        #expect(firstParagraphIDs.isDisjoint(with: Set(second.paragraphs.map(\.id))))
        #expect(firstQuestionIDs.isDisjoint(with: Set(second.questions.map(\.id))))
        #expect(firstOptionIDs.isDisjoint(with: Set(second.questions.flatMap(\.options).map(\.id))))
    }

    @Test("Article failure leaves an empty draft and retries from article")
    func retriesArticleFailure() async throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let provider = PipelineTestProvider(
            fixtures: makeFixtures(),
            failureStage: .article
        )
        let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)

        await expectStartFailure(pipeline)
        let document = try fetchOnlyDocument(in: container.mainContext)
        let job = try #require(document.processingJobs.first)

        #expect(document.state == .failed)
        #expect(document.paragraphs.isEmpty)
        #expect(document.questions.isEmpty)
        #expect(job.stage == .failed)
        #expect(job.failedStage == .generatingArticle)
        #expect(job.lastErrorCode == .timeout)

        _ = try await pipeline.retry(job)
        #expect(document.state == .ready)
        #expect(job.retryCount == 1)
        #expect(await provider.callCounts() == .init(article: 2, questions: 1, translation: 1))
    }

    @Test("Question failure preserves the article and retries only questions onward")
    func retriesQuestionFailure() async throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let provider = PipelineTestProvider(
            fixtures: makeFixtures(),
            failureStage: .questions
        )
        let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)

        await expectStartFailure(pipeline)
        let document = try fetchOnlyDocument(in: container.mainContext)
        let job = try #require(document.processingJobs.first)

        #expect(document.paragraphs.count == 5)
        #expect(document.questions.isEmpty)
        #expect(job.failedStage == .generatingQuestions)

        _ = try await pipeline.retry(job)
        #expect(document.state == .ready)
        #expect(await provider.callCounts() == .init(article: 1, questions: 2, translation: 1))
    }

    @Test("Translation failure preserves article and questions and retries only translation")
    func retriesTranslationFailure() async throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let provider = PipelineTestProvider(
            fixtures: makeFixtures(),
            failureStage: .translation
        )
        let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)

        await expectStartFailure(pipeline)
        let document = try fetchOnlyDocument(in: container.mainContext)
        let job = try #require(document.processingJobs.first)

        #expect(document.paragraphs.count == 5)
        #expect(document.questions.count == 5)
        #expect(document.paragraphs.allSatisfy { $0.translatedText == nil })
        #expect(job.failedStage == .translating)

        _ = try await pipeline.retry(job)
        #expect(document.state == .ready)
        #expect(document.paragraphs.allSatisfy { $0.translatedText != nil })
        #expect(await provider.callCounts() == .init(article: 1, questions: 1, translation: 2))
    }

    @Test("Final validation failure is recorded and retries without another provider call")
    func retriesFinalValidationFailure() async throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let provider = PipelineTestProvider(
            fixtures: makeFixtures(),
            failureStage: .translation
        )
        let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)

        await expectStartFailure(pipeline)
        let document = try fetchOnlyDocument(in: container.mainContext)
        let job = try #require(document.processingJobs.first)

        // 模拟 App 在译文阶段被外部写入不完整草稿后，重新从最终校验开始。
        job.stage = .validating
        job.failedStage = nil
        document.state = .processing
        try container.mainContext.save()

        do {
            _ = try await pipeline.resume(job)
            Issue.record("Expected final validation failure")
        } catch let error as AIProviderError {
            guard case .validationFailed = error else {
                Issue.record("Expected validation error")
                return
            }
        }

        #expect(job.stage == .failed)
        #expect(job.failedStage == .validating)
        #expect(job.lastErrorCode == .validation)
        #expect(await provider.callCounts() == .init(article: 1, questions: 1, translation: 1))

        for paragraph in document.paragraphs {
            paragraph.translatedText = "修复后的译文。"
            paragraph.translationLanguage = "zh-Hans"
            paragraph.translationModel = "test-model"
        }
        try container.mainContext.save()

        _ = try await pipeline.retry(job)
        #expect(document.state == .ready)
        #expect(job.retryCount == 1)
        #expect(await provider.callCounts() == .init(article: 1, questions: 1, translation: 1))
    }

    @Test("Cancelling an in-flight translation saves the draft and can resume that stage")
    func cancellationAndRetry() async throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let provider = PipelineTestProvider(
            fixtures: makeFixtures(),
            suspendedTranslationAttempts: 1
        )
        let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)

        let generationTask = Task { @MainActor in
            _ = try await pipeline.start(makeRequest())
        }
        for _ in 0..<100 where !(await provider.translationHasStarted()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.translationHasStarted())
        generationTask.cancel()

        do {
            _ = try await generationTask.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Pipeline 将取消保存为可恢复状态，再向调用方保留 Task 取消语义。
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let document = try fetchOnlyDocument(in: container.mainContext)
        let job = try #require(document.processingJobs.first)
        #expect(document.state == .draft)
        #expect(document.paragraphs.count == 5)
        #expect(document.questions.count == 5)
        #expect(job.stage == .cancelled)
        #expect(job.failedStage == .translating)
        #expect(job.lastErrorCode == .cancelled)

        _ = try await pipeline.retry(job)
        #expect(document.state == .ready)
        #expect(job.retryCount == 1)
        #expect(await provider.callCounts() == .init(article: 1, questions: 1, translation: 2))
    }

    @Test("An interrupted job is discovered and resumes from its persisted next stage")
    func resumesAfterStoreReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let storeURL = directory.appending(path: "Pipeline.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let container = try makeDiskContainer(at: storeURL)
            let provider = PipelineTestProvider(
                fixtures: makeFixtures(),
                failureStage: .questions
            )
            let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)
            await expectStartFailure(pipeline)

            // 模拟文章阶段保存后、App 在出题请求期间被系统终止。
            let document = try fetchOnlyDocument(in: container.mainContext)
            let job = try #require(document.processingJobs.first)
            job.stage = .generatingQuestions
            job.failedStage = nil
            job.lastErrorCode = nil
            job.lastError = nil
            document.state = .processing
            try container.mainContext.save()
        }

        do {
            let container = try makeDiskContainer(at: storeURL)
            let provider = PipelineTestProvider(fixtures: makeFixtures())
            let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)
            let jobs = try pipeline.resumableJobs()
            let job = try #require(jobs.first)

            #expect(jobs.count == 1)
            #expect(job.stage == .generatingQuestions)
            let document = try await pipeline.resume(job)

            #expect(document.state == .ready)
            #expect(document.processingJobs.first?.stage == .completed)
            #expect(await provider.callCounts() == .init(article: 0, questions: 1, translation: 1))
        }
    }

    @Test("Invalid input is rejected before a draft is inserted")
    func rejectsInvalidInputBeforePersistence() async throws {
        let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
        let provider = PipelineTestProvider(fixtures: makeFixtures())
        let pipeline = GenerationPipeline(modelContext: container.mainContext, provider: provider)
        let invalidRequest = ReadingGenerationRequest(topic: "  ", skill: try loadSkill())

        do {
            _ = try await pipeline.start(invalidRequest)
            Issue.record("Expected invalid input")
        } catch let error as ReadingPromptBuilderError {
            #expect(error == .emptyTopic)
        }

        #expect(try container.mainContext.fetchCount(FetchDescriptor<ReadingDocument>()) == 0)
        #expect(await provider.callCounts() == .init())
    }

    private func expectStartFailure(_ pipeline: GenerationPipeline) async {
        do {
            _ = try await pipeline.start(makeRequest())
            Issue.record("Expected pipeline failure")
        } catch let error as AIProviderError {
            #expect(error == .timeout)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func fetchOnlyDocument(in context: ModelContext) throws -> ReadingDocument {
        let documents = try context.fetch(FetchDescriptor<ReadingDocument>())
        #expect(documents.count == 1)
        return try #require(documents.first)
    }

    private func makeRequest() -> ReadingGenerationRequest {
        ReadingGenerationRequest(
            topic: "How urban gardens help neighborhoods",
            genre: "popular science",
            targetLanguage: "zh-Hans",
            translationModel: "test-model",
            skill: try! loadSkill()
        )
    }

    private func loadSkill() throws -> ReadingSkill {
        try ReadingSkillLoader().loadBuiltInSkill()
    }

    private func makeFixtures() -> MockAIProvider.Fixtures {
        let paragraphs = (1...5).map { index in
            GeneratedParagraph(
                id: fixtureUUID(group: 1, index: index),
                text: "Paragraph \(index) explains one benefit of a neighborhood garden."
            )
        }
        let questions = (1...5).map { questionIndex in
            let options = (1...4).map { optionIndex in
                GeneratedQuestionOption(
                    id: fixtureUUID(group: 2, index: questionIndex * 10 + optionIndex),
                    text: "Question \(questionIndex) option \(optionIndex)"
                )
            }
            return GeneratedQuestion(
                id: fixtureUUID(group: 3, index: questionIndex),
                stem: "What does paragraph \(questionIndex) explain?",
                options: options,
                correctOptionID: options[0].id,
                explanation: "第 \(questionIndex) 段直接说明了这一点。",
                evidenceParagraphIDs: [paragraphs[questionIndex - 1].id]
            )
        }
        let translations = paragraphs.enumerated().map { index, paragraph in
            ParagraphTranslation(
                paragraphID: paragraph.id,
                translatedText: "第 \(index + 1) 段的译文。"
            )
        }
        return .init(
            article: .init(title: "Gardens That Bring Neighbors Together", paragraphs: paragraphs),
            questions: questions,
            translations: translations
        )
    }

    private func fixtureUUID(group: Int, index: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-0000-0000-%012X", group, index))!
    }

    private func makeDiskContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: LectionSchema.schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: LectionSchema.schema, configurations: [configuration])
    }
}

private actor PipelineTestProvider: AIProvider {
    enum Stage: Sendable {
        case article
        case questions
        case translation
    }

    struct CallCounts: Equatable, Sendable {
        var article = 0
        var questions = 0
        var translation = 0
    }

    private let fixtures: MockAIProvider.Fixtures
    private let failureStage: Stage?
    private var failureAttemptsRemaining: Int
    private var suspendedTranslationAttempts: Int
    private var counts = CallCounts()
    private var didStartTranslation = false

    init(
        fixtures: MockAIProvider.Fixtures,
        failureStage: Stage? = nil,
        failureAttempts: Int = 1,
        suspendedTranslationAttempts: Int = 0
    ) {
        self.fixtures = fixtures
        self.failureStage = failureStage
        self.failureAttemptsRemaining = failureAttempts
        self.suspendedTranslationAttempts = suspendedTranslationAttempts
    }

    func generateArticle(request: ArticleGenerationRequest) async throws -> GeneratedArticle {
        counts.article += 1
        try failIfNeeded(at: .article)
        return fixtures.article
    }

    func generateQuestions(request: QuestionGenerationRequest) async throws -> [GeneratedQuestion] {
        counts.questions += 1
        try failIfNeeded(at: .questions)
        let paragraphIDs = Dictionary(
            uniqueKeysWithValues: zip(fixtures.article.paragraphs, request.sourceParagraphs)
                .map { articleParagraph, sourceParagraph in
                    (articleParagraph.id, sourceParagraph.id)
                }
        )
        return fixtures.questions.map { question in
            GeneratedQuestion(
                id: question.id,
                stem: question.stem,
                options: question.options,
                correctOptionID: question.correctOptionID,
                explanation: question.explanation,
                evidenceParagraphIDs: question.evidenceParagraphIDs.compactMap { paragraphIDs[$0] }
            )
        }
    }

    func translateParagraphs(request: TranslationRequest) async throws -> [ParagraphTranslation] {
        counts.translation += 1
        didStartTranslation = true
        try failIfNeeded(at: .translation)
        if suspendedTranslationAttempts > 0 {
            suspendedTranslationAttempts -= 1
            try await Task.sleep(for: .seconds(60))
        }
        return zip(fixtures.translations, request.sourceParagraphs).map { translation, source in
            ParagraphTranslation(
                paragraphID: source.id,
                translatedText: translation.translatedText
            )
        }
    }

    func callCounts() -> CallCounts {
        counts
    }

    func translationHasStarted() -> Bool {
        didStartTranslation
    }

    private func failIfNeeded(at stage: Stage) throws {
        guard failureStage == stage, failureAttemptsRemaining > 0 else {
            return
        }
        failureAttemptsRemaining -= 1
        throw AIProviderError.timeout
    }
}
