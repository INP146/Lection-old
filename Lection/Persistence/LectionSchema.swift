import SwiftData

enum LectionSchema {
    static let schema = Schema([
        ReadingDocument.self,
        Paragraph.self,
        Question.self,
        QuestionOption.self,
        ProcessingJob.self,
    ])

    static func makeContainer(isStoredInMemoryOnly: Bool = false) throws -> ModelContainer {
        // 明确关闭 CloudKit；第一阶段的所有业务数据只保存在当前设备。
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
