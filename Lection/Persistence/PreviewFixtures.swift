import Foundation
import SwiftData

@MainActor
enum PreviewFixtures {
    static func makeDocument() -> ReadingDocument {
        let firstParagraph = Paragraph(
            order: 0,
            originalText: "Cities become quieter after dark, but many animals are just beginning their day.",
            translatedText: "天黑后城市安静下来，但许多动物才刚刚开始一天的活动。",
            translationLanguage: "zh-Hans",
            translationModel: "fixture"
        )
        let secondParagraph = Paragraph(
            order: 1,
            originalText: "Foxes and owls use the empty streets and parks to search for food.",
            translatedText: "狐狸和猫头鹰会利用空旷的街道与公园寻找食物。",
            translationLanguage: "zh-Hans",
            translationModel: "fixture"
        )

        let correctOption = QuestionOption(order: 0, text: "They search for food.")
        let question = Question(
            order: 0,
            stem: "Why do some animals enter quiet streets at night?",
            correctOptionID: correctOption.id,
            explanation: "The second paragraph says that they use these places to search for food.",
            evidenceParagraphIDs: [secondParagraph.id]
        )
        question.options = [
            correctOption,
            QuestionOption(order: 1, text: "They look for people."),
            QuestionOption(order: 2, text: "They avoid the parks."),
        ]

        let document = ReadingDocument(
            title: "City Animals After Dark",
            state: .ready,
            skillID: "general-english-reading",
            skillVersion: 1
        )
        document.paragraphs = [firstParagraph, secondParagraph]
        document.questions = [question]
        document.processingJobs = [ProcessingJob(stage: .completed)]
        return document
    }

    static func makeContainer() -> ModelContainer {
        do {
            let container = try LectionSchema.makeContainer(isStoredInMemoryOnly: true)
            container.mainContext.insert(makeDocument())
            try container.mainContext.save()
            return container
        } catch {
            fatalError("无法创建预览数据容器：\(error.localizedDescription)")
        }
    }
}
