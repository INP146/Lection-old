import Foundation
import SwiftData

/// 一次可恢复的内容处理任务。中间结果由后续 Pipeline 按阶段写入。
@Model
final class ProcessingJob {
    @Attribute(.unique) var id: UUID
    var stageRawValue: String
    var failedStageRawValue: String?
    var retryCount: Int
    var lastError: String?
    var intermediatePayload: Data?
    var createdAt: Date
    var updatedAt: Date

    var document: ReadingDocument?

    /// 未知状态回退到失败，防止 App 把未完成任务误报为完成。
    var stage: ProcessingStage {
        get { ProcessingStage(rawValue: stageRawValue) ?? .failed }
        set { stageRawValue = newValue.rawValue }
    }

    var failedStage: ProcessingStage? {
        get { failedStageRawValue.flatMap(ProcessingStage.init(rawValue:)) }
        set { failedStageRawValue = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        stage: ProcessingStage,
        failedStage: ProcessingStage? = nil,
        retryCount: Int = 0,
        lastError: String? = nil,
        intermediatePayload: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.stageRawValue = stage.rawValue
        self.failedStageRawValue = failedStage?.rawValue
        self.retryCount = retryCount
        self.lastError = lastError
        self.intermediatePayload = intermediatePayload
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// 同时覆盖第一阶段生成流程与后续导入流程，避免持久化状态迁移时改写旧记录。
enum ProcessingStage: String, Codable {
    case extracting
    case classifying
    case structuring
    case generatingArticle
    case generatingQuestions
    case translating
    case validating
    case completed
    case failed
}
