import Foundation

protocol AIProvider: Sendable {
    func generateArticle(
        request: ArticleGenerationRequest
    ) async throws -> GeneratedArticle

    func generateQuestions(
        request: QuestionGenerationRequest
    ) async throws -> [GeneratedQuestion]

    func translateParagraphs(
        request: TranslationRequest
    ) async throws -> [ParagraphTranslation]
}

struct AIRequestPrompt: Equatable, Sendable {
    let system: String
    let user: String

    init(system: String, user: String) {
        self.system = system
        self.user = user
    }

    func appendingOutputRepairInstruction() -> AIRequestPrompt {
        AIRequestPrompt(
            system: system,
            user: user + "\n\nYour previous response was invalid. Return only one complete JSON value that exactly matches the requested schema."
        )
    }
}

struct ArticleGenerationRequest: Equatable, Sendable {
    let prompt: AIRequestPrompt
    let minimumParagraphCount: Int
    let maximumParagraphCount: Int
    let minimumWordCount: Int
    let maximumWordCount: Int
    let preferredWordCount: Int?
    let preferredWordCountTolerance: Int

    init(
        prompt: AIRequestPrompt,
        minimumParagraphCount: Int,
        maximumParagraphCount: Int,
        minimumWordCount: Int,
        maximumWordCount: Int,
        preferredWordCount: Int? = nil,
        preferredWordCountTolerance: Int = 50
    ) {
        self.prompt = prompt
        self.minimumParagraphCount = minimumParagraphCount
        self.maximumParagraphCount = maximumParagraphCount
        self.minimumWordCount = minimumWordCount
        self.maximumWordCount = maximumWordCount
        self.preferredWordCount = preferredWordCount
        self.preferredWordCountTolerance = preferredWordCountTolerance
    }
}

struct QuestionGenerationRequest: Equatable, Sendable {
    static let expectedOptionCount = 4

    let prompt: AIRequestPrompt
    let sourceParagraphs: [SourceParagraph]
    let expectedQuestionCount: Int
    let questionPlan: [ReadingSkill.QuestionPlanItem]

    init(
        prompt: AIRequestPrompt,
        sourceParagraphs: [SourceParagraph],
        expectedQuestionCount: Int = 5,
        questionPlan: [ReadingSkill.QuestionPlanItem]
    ) {
        self.prompt = prompt
        self.sourceParagraphs = sourceParagraphs
        self.expectedQuestionCount = expectedQuestionCount
        self.questionPlan = questionPlan
    }
}

struct TranslationRequest: Equatable, Sendable {
    let prompt: AIRequestPrompt
    let sourceParagraphs: [SourceParagraph]
    let targetLanguage: String

    init(
        prompt: AIRequestPrompt,
        sourceParagraphs: [SourceParagraph],
        targetLanguage: String
    ) {
        self.prompt = prompt
        self.sourceParagraphs = sourceParagraphs
        self.targetLanguage = targetLanguage
    }
}

struct SourceParagraph: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let text: String
}

struct GeneratedArticle: Codable, Equatable, Sendable {
    let title: String
    let paragraphs: [GeneratedParagraph]
}

struct GeneratedParagraph: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let text: String
}

struct GeneratedQuestion: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let category: String
    let difficulty: String
    let stem: String
    let options: [GeneratedQuestionOption]
    let correctOptionID: UUID
    let explanation: String
    let evidenceParagraphIDs: [UUID]
}

struct GeneratedQuestionOption: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let text: String
}

struct ParagraphTranslation: Codable, Equatable, Sendable {
    let paragraphID: UUID
    let translatedText: String
}

struct GeneratedQuestionEnvelope: Codable, Equatable, Sendable {
    let questions: [GeneratedQuestion]
}

struct ParagraphTranslationEnvelope: Codable, Equatable, Sendable {
    let translations: [ParagraphTranslation]
}

struct AIValidationIssue: Equatable, Sendable {
    enum Code: String, Sendable {
        case invalidRequest
        case emptyTitle
        case paragraphCountOutOfRange
        case wordCountOutOfRange
        case preferredWordCountMissed
        case emptyParagraph
        case duplicateParagraphID
        case questionCountMismatch
        case questionPlanMismatch
        case duplicateQuestionID
        case emptyQuestionCategory
        case emptyQuestionDifficulty
        case emptyQuestionStem
        case optionCountMismatch
        case duplicateOptionID
        case duplicateOptionText
        case emptyOption
        case missingCorrectOption
        case emptyExplanation
        case missingEvidence
        case unknownEvidenceParagraph
        case duplicateTranslationParagraphID
        case missingTranslation
        case unknownTranslationParagraph
        case emptyTranslation
    }

    let code: Code
    let path: String
}

enum AIProviderError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case timeout
    case network(URLError.Code)
    case invalidAPIKey
    case modelNotFound
    case rateLimited
    case server(statusCode: Int, message: String?)
    case invalidHTTPResponse
    case invalidProviderResponse
    case responseTooLarge
    case emptyResponse
    case outputDecodingFailed
    case validationFailed([AIValidationIssue])

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            message
        case .timeout:
            "模型请求超时。"
        case .network:
            "无法连接模型服务，请检查网络和 Base URL。"
        case .invalidAPIKey:
            "API Key 无效或没有访问权限。"
        case .modelNotFound:
            "没有找到配置的模型。"
        case .rateLimited:
            "模型服务请求过于频繁，请稍后重试。"
        case let .server(statusCode, message):
            message.map { "模型服务返回 HTTP \(statusCode)：\($0)" }
                ?? "模型服务返回 HTTP \(statusCode)。"
        case .invalidHTTPResponse:
            "模型服务返回了无法识别的 HTTP 响应。"
        case .invalidProviderResponse:
            "模型服务响应格式与 OpenAI-compatible Chat Completions API 不兼容。"
        case .responseTooLarge:
            "模型服务返回内容过大，已停止处理。"
        case .emptyResponse:
            "模型服务没有返回内容。"
        case .outputDecodingFailed:
            "模型输出不是有效的结构化 JSON。"
        case let .validationFailed(issues):
            "模型输出未通过业务校验（\(issues.count) 项）。"
        }
    }
}
