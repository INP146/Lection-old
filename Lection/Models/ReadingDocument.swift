import Foundation
import SwiftData

/// 本地保存的一篇阅读材料，也是段落、题目和处理任务的聚合根。
@Model
final class ReadingDocument {
    @Attribute(.unique) var id: UUID
    var title: String

    // 枚举以原始字符串持久化，便于 SwiftData 查询和后续增加新状态。
    var sourceTypeRawValue: String
    var stateRawValue: String

    var skillID: String?
    var skillVersion: Int?
    var createdAt: Date
    var updatedAt: Date

    // ReadingDocument 是本地内容的聚合根。级联删除保证移除资料时不会残留子对象。
    @Relationship(deleteRule: .cascade, inverse: \Paragraph.document)
    var paragraphs: [Paragraph] = []

    @Relationship(deleteRule: .cascade, inverse: \Question.document)
    var questions: [Question] = []

    @Relationship(deleteRule: .cascade, inverse: \ProcessingJob.document)
    var processingJobs: [ProcessingJob] = []

    /// 业务代码使用的类型安全来源；遇到无法识别的旧值时回退为生成内容。
    var sourceType: DocumentSourceType {
        get { DocumentSourceType(rawValue: sourceTypeRawValue) ?? .generated }
        set { sourceTypeRawValue = newValue.rawValue }
    }

    /// 业务代码使用的类型安全状态；遇到无法识别的旧值时按草稿处理。
    var state: DocumentState {
        get { DocumentState(rawValue: stateRawValue) ?? .draft }
        set { stateRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        sourceType: DocumentSourceType = .generated,
        state: DocumentState = .draft,
        skillID: String? = nil,
        skillVersion: Int? = nil,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceTypeRawValue = sourceType.rawValue
        self.stateRawValue = state.rawValue
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// 阅读材料最初进入 App 的方式。
enum DocumentSourceType: String, Codable {
    case generated
    case imported
}

/// 阅读材料在本地生命周期中的状态。
enum DocumentState: String, Codable {
    case draft
    case processing
    case ready
    case failed
}
