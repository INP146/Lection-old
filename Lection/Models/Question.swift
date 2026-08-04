import Foundation
import SwiftData

/// 一道阅读题。第一阶段只展示单选题，但模型保留后续题型需要的边界。
@Model
final class Question {
    @Attribute(.unique) var id: UUID
    var order: Int
    var typeRawValue: String
    var stem: String
    var correctOptionID: UUID?
    var referenceAnswer: String?
    var explanation: String
    var evidenceParagraphIDs: [UUID]
    var originRawValue: String
    var confidence: Double?
    var selectedOptionID: UUID?
    var answeredAt: Date?

    var document: ReadingDocument?

    @Relationship(deleteRule: .cascade, inverse: \QuestionOption.question)
    var options: [QuestionOption] = []

    /// 未识别的旧题型不会被误判为单选题，而是作为简答题等待人工处理。
    var type: QuestionType {
        get { QuestionType(rawValue: typeRawValue) ?? .shortAnswer }
        set { typeRawValue = newValue.rawValue }
    }

    /// 无法识别来源时按 AI 生成处理，避免把内容错误标记为用户编辑。
    var origin: ContentOrigin {
        get { ContentOrigin(rawValue: originRawValue) ?? .generated }
        set { originRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        order: Int,
        type: QuestionType = .singleChoice,
        stem: String,
        correctOptionID: UUID? = nil,
        referenceAnswer: String? = nil,
        explanation: String,
        evidenceParagraphIDs: [UUID],
        origin: ContentOrigin = .generated,
        confidence: Double? = nil,
        selectedOptionID: UUID? = nil,
        answeredAt: Date? = nil
    ) {
        self.id = id
        self.order = order
        self.typeRawValue = type.rawValue
        self.stem = stem
        self.correctOptionID = correctOptionID
        self.referenceAnswer = referenceAnswer
        self.explanation = explanation
        self.evidenceParagraphIDs = evidenceParagraphIDs
        self.originRawValue = origin.rawValue
        self.confidence = confidence
        self.selectedOptionID = selectedOptionID
        self.answeredAt = answeredAt
    }

    /// 提交前不暴露判分结果；提交后只比较本地稳定选项 ID。
    var isCorrect: Bool? {
        guard answeredAt != nil,
              let selectedOptionID,
              let correctOptionID else {
            return nil
        }
        return selectedOptionID == correctOptionID
    }
}

/// 选择题选项单独建模，以便保持稳定 ID 并支持级联删除。
@Model
final class QuestionOption {
    @Attribute(.unique) var id: UUID
    var order: Int
    var text: String

    var question: Question?

    init(id: UUID = UUID(), order: Int, text: String) {
        self.id = id
        self.order = order
        self.text = text
    }
}

enum QuestionType: String, Codable {
    case singleChoice
    case trueFalse
    case shortAnswer
}

enum ContentOrigin: String, Codable {
    case imported
    case generated
    case aiCompleted
    case userEdited
}
