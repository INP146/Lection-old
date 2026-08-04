import Foundation
import Testing
@testable import Lection

@Suite("AI response validation")
struct AIResponseValidatorTests {
    private let paragraphID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let secondParagraphID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    @Test("A complete article passes validation")
    func validArticle() throws {
        let article = GeneratedArticle(
            title: "Night Trains",
            paragraphs: [
                .init(id: paragraphID, text: "The train leaves after sunset."),
                .init(id: secondParagraphID, text: "It reaches the coast at dawn."),
            ]
        )

        try AIResponseValidator.validate(
            article: article,
            for: articleRequest(minimum: 2, maximum: 3)
        )
    }

    @Test("Article validation reports empty content and duplicate IDs")
    func invalidArticle() throws {
        let article = GeneratedArticle(
            title: " ",
            paragraphs: [
                .init(id: paragraphID, text: ""),
                .init(id: paragraphID, text: "Valid text"),
            ]
        )

        let issues = validationIssues {
            try AIResponseValidator.validate(
                article: article,
                for: articleRequest(minimum: 3, maximum: 4)
            )
        }
        #expect(Set(issues.map(\.code)) == [
            .emptyTitle,
            .paragraphCountOutOfRange,
            .emptyParagraph,
            .duplicateParagraphID,
        ])
    }

    @Test("Question validation enforces options, answers, and evidence")
    func invalidQuestion() throws {
        let duplicateOptionID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let question = GeneratedQuestion(
            id: UUID(),
            stem: " ",
            options: [
                .init(id: duplicateOptionID, text: "Same"),
                .init(id: duplicateOptionID, text: " same "),
            ],
            correctOptionID: UUID(),
            explanation: "",
            evidenceParagraphIDs: [UUID()]
        )
        let request = QuestionGenerationRequest(
            prompt: prompt,
            sourceParagraphs: [.init(id: paragraphID, text: "Source")],
            expectedQuestionCount: 1
        )

        let issues = validationIssues {
            try AIResponseValidator.validate(questions: [question], for: request)
        }
        #expect(Set(issues.map(\.code)) == [
            .emptyQuestionStem,
            .emptyExplanation,
            .insufficientOptions,
            .duplicateOptionID,
            .duplicateOptionText,
            .missingCorrectOption,
            .unknownEvidenceParagraph,
        ])
    }

    @Test("Translation validation reports missing and unknown paragraphs")
    func invalidTranslations() throws {
        let unknownID = UUID()
        let request = TranslationRequest(
            prompt: prompt,
            sourceParagraphs: [
                .init(id: paragraphID, text: "One"),
                .init(id: secondParagraphID, text: "Two"),
            ],
            targetLanguage: "zh-Hans"
        )
        let translations = [
            ParagraphTranslation(paragraphID: paragraphID, translatedText: ""),
            ParagraphTranslation(paragraphID: unknownID, translatedText: "未知"),
        ]

        let issues = validationIssues {
            try AIResponseValidator.validate(translations: translations, for: request)
        }
        #expect(Set(issues.map(\.code)) == [
            .missingTranslation,
            .unknownTranslationParagraph,
            .emptyTranslation,
        ])
    }

    @Test("Decoder extracts JSON from Markdown without changing string content")
    func cleansStructuredOutput() throws {
        let content = """
        Here is the result:
        ```json
        {"title":"Braces { stay } in text","paragraphs":[{"id":"\(paragraphID.uuidString)","text":"Body"}]}
        ```
        """

        let article = try StructuredResponseDecoder.decode(GeneratedArticle.self, from: content)
        #expect(article.title == "Braces { stay } in text")
        #expect(article.paragraphs.first?.id == paragraphID)
    }

    private var prompt: AIRequestPrompt {
        .init(system: "system", user: "user")
    }

    private func articleRequest(minimum: Int, maximum: Int) -> ArticleGenerationRequest {
        .init(prompt: prompt, minimumParagraphCount: minimum, maximumParagraphCount: maximum)
    }

    private func validationIssues(_ action: () throws -> Void) -> [AIValidationIssue] {
        do {
            try action()
            Issue.record("Expected validation to fail")
            return []
        } catch let AIProviderError.validationFailed(issues) {
            return issues
        } catch {
            Issue.record("Unexpected error: \(error)")
            return []
        }
    }
}
