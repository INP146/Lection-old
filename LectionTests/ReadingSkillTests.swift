import Foundation
import Testing
@testable import Lection

@Suite("Reading skill and prompts")
struct ReadingSkillTests {
    private let firstParagraphID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    private let secondParagraphID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!

    @Test("Bundled skill decodes with its version and generation constraints")
    func loadsBundledSkill() throws {
        let skill = try ReadingSkillLoader().loadBuiltInSkill()

        #expect(skill.schemaVersion == 1)
        #expect(skill.id == "general-english-reading")
        #expect(skill.version == 1)
        #expect(skill.targetWordCount.closedRange == 350...500)
        #expect(skill.paragraphCount.closedRange == 5...7)
        #expect(skill.questionCount == 5)
    }

    @Test("Unsupported skill schema versions are rejected")
    func rejectsUnsupportedSchema() throws {
        let currentData = try bundledSkillData()
        let object = try #require(JSONSerialization.jsonObject(with: currentData) as? [String: Any])
        var changedObject = object
        changedObject["schemaVersion"] = 999
        let changedData = try JSONSerialization.data(withJSONObject: changedObject)

        #expect(throws: ReadingSkillError.unsupportedSchemaVersion(999)) {
            try ReadingSkillLoader().decode(changedData)
        }
    }

    @Test("Article prompt carries skill provenance and all article bounds")
    func buildsArticlePrompt() throws {
        let skill = try ReadingSkillLoader().loadBuiltInSkill()
        let request = try ArticlePromptBuilder.makeRequest(
            skill: skill,
            topic: "How city parks cool neighborhoods",
            genre: "popular science",
            preferredWordCount: 425
        )

        #expect(request.minimumParagraphCount == 5)
        #expect(request.maximumParagraphCount == 7)
        #expect(request.prompt.user.contains("general-english-reading"))
        #expect(request.prompt.user.contains("version: 1"))
        #expect(request.prompt.user.contains("350-500 English words"))
        #expect(request.prompt.user.contains("approximately 425 English words"))
        #expect(request.prompt.user.contains("5-7 paragraphs"))
        #expect(request.prompt.user.contains("unique UUID"))
        #expect(request.prompt.user.contains(skill.promptInstructions))
    }

    @Test("Document records skill ID and version together")
    func recordsSkillProvenance() throws {
        let skill = try ReadingSkillLoader().loadBuiltInSkill()
        let document = ReadingDocument(title: "Draft")

        document.recordGenerationSkill(skill)

        #expect(document.skillID == skill.id)
        #expect(document.skillVersion == skill.version)
    }

    @Test("Question prompt preserves source IDs and requires answers, Chinese explanations, and evidence")
    func buildsQuestionPrompt() throws {
        let skill = try ReadingSkillLoader().loadBuiltInSkill()
        let paragraphs = sourceParagraphs
        let request = try QuestionPromptBuilder.makeRequest(
            skill: skill,
            sourceParagraphs: paragraphs
        )

        #expect(request.expectedQuestionCount == 5)
        #expect(request.sourceParagraphs == paragraphs)
        #expect(request.prompt.user.contains(firstParagraphID.uuidString))
        #expect(request.prompt.user.contains(secondParagraphID.uuidString))
        #expect(request.prompt.user.contains("correctOptionID"))
        #expect(request.prompt.user.contains("Simplified Chinese"))
        #expect(request.prompt.user.contains("evidenceParagraphIDs"))
        #expect(request.prompt.user.contains("detail comprehension: 2"))
        #expect(request.prompt.user.contains(skill.distractorRules[0]))
    }

    @Test("Translation prompt requires exact and complete paragraph ID coverage")
    func buildsTranslationPrompt() throws {
        let paragraphs = sourceParagraphs
        let request = try TranslationPromptBuilder.makeRequest(
            sourceParagraphs: paragraphs,
            targetLanguage: "zh-Hans"
        )

        #expect(request.sourceParagraphs == paragraphs)
        #expect(request.targetLanguage == "zh-Hans")
        #expect(request.prompt.user.contains(firstParagraphID.uuidString))
        #expect(request.prompt.user.contains("exactly one translation for every source paragraph"))
        #expect(request.prompt.user.contains("Copy each source `id` unchanged into `paragraphID`"))
        #expect(request.prompt.user.contains("Do not omit, duplicate, merge, split, reorder, or invent"))
    }

    @Test("Prompt builders reject invalid user and source input before provider calls")
    func rejectsInvalidPromptInputs() throws {
        let skill = try ReadingSkillLoader().loadBuiltInSkill()

        #expect(throws: ReadingPromptBuilderError.emptyTopic) {
            try ArticlePromptBuilder.makeRequest(skill: skill, topic: "  ")
        }
        #expect(throws: ReadingPromptBuilderError.unsupportedGenre("legal brief")) {
            try ArticlePromptBuilder.makeRequest(
                skill: skill,
                topic: "A topic",
                genre: "legal brief"
            )
        }
        #expect(throws: ReadingPromptBuilderError.preferredWordCountOutOfRange) {
            try ArticlePromptBuilder.makeRequest(
                skill: skill,
                topic: "A topic",
                preferredWordCount: 900
            )
        }
        #expect(throws: ReadingPromptBuilderError.duplicateSourceParagraphID) {
            try QuestionPromptBuilder.makeRequest(
                skill: skill,
                sourceParagraphs: [
                    .init(id: firstParagraphID, text: "One"),
                    .init(id: firstParagraphID, text: "Two"),
                ]
            )
        }
        #expect(throws: ReadingPromptBuilderError.emptyTargetLanguage) {
            try TranslationPromptBuilder.makeRequest(
                sourceParagraphs: sourceParagraphs,
                targetLanguage: "\n"
            )
        }
    }

    private var sourceParagraphs: [SourceParagraph] {
        [
            .init(id: firstParagraphID, text: "A park can cool nearby streets."),
            .init(id: secondParagraphID, text: "Trees provide shade and release water vapor."),
        ]
    }

    private func bundledSkillData() throws -> Data {
        let bundle = Bundle(for: TestBundleToken.self)
        let url = try #require(
            bundle.url(forResource: "general-english-reading", withExtension: "json")
                ?? Bundle.main.url(forResource: "general-english-reading", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }
}

private final class TestBundleToken {}
