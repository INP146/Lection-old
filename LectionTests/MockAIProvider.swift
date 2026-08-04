import Foundation
@testable import Lection

struct MockAIProvider: AIProvider, Sendable {
    enum Scenario: Sendable {
        case success(Fixtures)
        case timeout
        case invalidJSON
        case partialTranslation(Fixtures)
    }

    struct Fixtures: Sendable {
        let article: GeneratedArticle
        let questions: [GeneratedQuestion]
        let translations: [ParagraphTranslation]
    }

    let scenario: Scenario

    func generateArticle(request: ArticleGenerationRequest) async throws -> GeneratedArticle {
        switch scenario {
        case let .success(fixtures), let .partialTranslation(fixtures):
            return fixtures.article
        case .timeout:
            throw AIProviderError.timeout
        case .invalidJSON:
            throw AIProviderError.outputDecodingFailed
        }
    }

    func generateQuestions(request: QuestionGenerationRequest) async throws -> [GeneratedQuestion] {
        switch scenario {
        case let .success(fixtures), let .partialTranslation(fixtures):
            return fixtures.questions
        case .timeout:
            throw AIProviderError.timeout
        case .invalidJSON:
            throw AIProviderError.outputDecodingFailed
        }
    }

    func translateParagraphs(request: TranslationRequest) async throws -> [ParagraphTranslation] {
        switch scenario {
        case let .success(fixtures):
            return fixtures.translations
        case .timeout:
            throw AIProviderError.timeout
        case .invalidJSON:
            throw AIProviderError.outputDecodingFailed
        case let .partialTranslation(fixtures):
            do {
                try AIResponseValidator.validate(translations: fixtures.translations, for: request)
                return fixtures.translations
            } catch let error as AIProviderError {
                throw error
            }
        }
    }
}
