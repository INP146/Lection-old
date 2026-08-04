import Foundation

/// App Bundle 中版本化的阅读生成规则。Provider 只接收最终 Prompt，不需要理解技能格式。
struct ReadingSkill: Codable, Equatable, Sendable, Identifiable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let id: String
    let version: Int
    let displayName: String
    let stage: String
    let supportedGenres: [String]
    let targetWordCount: IntegerRange
    let paragraphCount: IntegerRange
    let grammarRequirements: [String]
    let vocabularyConstraints: VocabularyConstraints
    let questionPlan: [QuestionPlanItem]
    let distractorRules: [String]
    let prohibitedContent: [String]
    let promptInstructions: String

    var questionCount: Int {
        questionPlan.reduce(0) { $0 + $1.count }
    }

    struct IntegerRange: Codable, Equatable, Sendable {
        let minimum: Int
        let maximum: Int

        var closedRange: ClosedRange<Int> {
            minimum...maximum
        }
    }

    struct VocabularyConstraints: Codable, Equatable, Sendable {
        let targetLevel: String
        let maximumUnfamiliarWordRatio: Double
        let requirements: [String]
    }

    /// `category` 和 `difficulty` 保持为数据字段，新增技能规则时无需修改 Provider 枚举。
    struct QuestionPlanItem: Codable, Equatable, Sendable {
        let category: String
        let count: Int
        let difficulty: String
    }
}

enum ReadingSkillError: LocalizedError, Equatable, Sendable {
    case resourceNotFound(String)
    case unreadableResource
    case invalidJSON
    case unsupportedSchemaVersion(Int)
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case let .resourceNotFound(name):
            "找不到内置阅读技能资源：\(name)。"
        case .unreadableResource:
            "无法读取阅读技能资源。"
        case .invalidJSON:
            "阅读技能资源不是有效的 JSON。"
        case let .unsupportedSchemaVersion(version):
            "不支持阅读技能格式版本 \(version)。"
        case let .invalidField(field):
            "阅读技能字段无效：\(field)。"
        }
    }
}

struct ReadingSkillLoader: Sendable {
    private let bundle: Bundle

    init(bundle: Bundle? = nil) {
        self.bundle = bundle ?? Bundle(for: ReadingSkillBundleToken.self)
    }

    func loadBuiltInSkill(named resourceName: String = "general-english-reading") throws -> ReadingSkill {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw ReadingSkillError.resourceNotFound(resourceName)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReadingSkillError.unreadableResource
        }
        return try decode(data)
    }

    func decode(_ data: Data) throws -> ReadingSkill {
        let skill: ReadingSkill
        do {
            skill = try JSONDecoder().decode(ReadingSkill.self, from: data)
        } catch {
            throw ReadingSkillError.invalidJSON
        }

        try validate(skill)
        return skill
    }

    private func validate(_ skill: ReadingSkill) throws {
        guard skill.schemaVersion == ReadingSkill.supportedSchemaVersion else {
            throw ReadingSkillError.unsupportedSchemaVersion(skill.schemaVersion)
        }
        guard !skill.id.trimmed.isEmpty else {
            throw ReadingSkillError.invalidField("id")
        }
        guard skill.version > 0 else {
            throw ReadingSkillError.invalidField("version")
        }
        guard !skill.displayName.trimmed.isEmpty else {
            throw ReadingSkillError.invalidField("displayName")
        }
        guard !skill.stage.trimmed.isEmpty else {
            throw ReadingSkillError.invalidField("stage")
        }
        guard !skill.supportedGenres.isEmpty,
              skill.supportedGenres.allSatisfy({ !$0.trimmed.isEmpty }) else {
            throw ReadingSkillError.invalidField("supportedGenres")
        }
        try validate(skill.targetWordCount, field: "targetWordCount")
        try validate(skill.paragraphCount, field: "paragraphCount")
        guard !skill.vocabularyConstraints.targetLevel.trimmed.isEmpty else {
            throw ReadingSkillError.invalidField("vocabularyConstraints.targetLevel")
        }
        guard (0...1).contains(skill.vocabularyConstraints.maximumUnfamiliarWordRatio) else {
            throw ReadingSkillError.invalidField("vocabularyConstraints.maximumUnfamiliarWordRatio")
        }
        guard !skill.questionPlan.isEmpty,
              skill.questionPlan.allSatisfy({
                  !$0.category.trimmed.isEmpty && !$0.difficulty.trimmed.isEmpty && $0.count > 0
              }) else {
            throw ReadingSkillError.invalidField("questionPlan")
        }
        guard !skill.distractorRules.isEmpty,
              skill.distractorRules.allSatisfy({ !$0.trimmed.isEmpty }) else {
            throw ReadingSkillError.invalidField("distractorRules")
        }
        guard !skill.promptInstructions.trimmed.isEmpty else {
            throw ReadingSkillError.invalidField("promptInstructions")
        }
    }

    private func validate(_ range: ReadingSkill.IntegerRange, field: String) throws {
        guard range.minimum > 0, range.maximum >= range.minimum else {
            throw ReadingSkillError.invalidField(field)
        }
    }
}

private final class ReadingSkillBundleToken {}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
