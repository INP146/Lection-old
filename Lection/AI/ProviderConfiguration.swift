import Foundation

struct ProviderConfiguration: Codable, Equatable, Sendable {
    static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    var baseURL: URL
    var modelName: String
    var requestTimeout: TimeInterval
    var supportsJSONSchema: Bool
    var supportsJSONObject: Bool

    static let `default` = ProviderConfiguration(
        baseURL: defaultBaseURL,
        modelName: "",
        requestTimeout: 60,
        supportsJSONSchema: true,
        supportsJSONObject: true
    )

    static func validated(
        baseURLText: String,
        modelName: String,
        requestTimeout: TimeInterval,
        supportsJSONSchema: Bool,
        supportsJSONObject: Bool
    ) throws -> ProviderConfiguration {
        let trimmedURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let components = URLComponents(string: trimmedURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let baseURL = components.url else {
            // 禁止凭据、查询参数和片段进入 Base URL，避免后续拼接接口路径时泄漏或产生歧义。
            throw ProviderConfigurationError.invalidBaseURL
        }

        guard !trimmedModelName.isEmpty else {
            throw ProviderConfigurationError.missingModelName
        }

        guard (15...180).contains(requestTimeout) else {
            throw ProviderConfigurationError.invalidRequestTimeout
        }

        return ProviderConfiguration(
            baseURL: baseURL,
            modelName: trimmedModelName,
            requestTimeout: requestTimeout,
            supportsJSONSchema: supportsJSONSchema,
            supportsJSONObject: supportsJSONObject
        )
    }
}

enum ProviderConfigurationError: LocalizedError, Equatable {
    case invalidBaseURL
    case missingModelName
    case invalidRequestTimeout

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Base URL 必须是有效的 HTTPS 地址，且不能包含账号、查询参数或片段。"
        case .missingModelName:
            "请输入模型名称。"
        case .invalidRequestTimeout:
            "请求超时时间必须在 15 到 180 秒之间。"
        }
    }
}

@MainActor
protocol ProviderConfigurationPersisting: AnyObject {
    func load() -> ProviderConfiguration
    func save(_ configuration: ProviderConfiguration) throws
}

@MainActor
final class UserDefaultsProviderConfigurationStore: ProviderConfigurationPersisting {
    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "provider.configuration.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func load() -> ProviderConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let configuration = try? decoder.decode(ProviderConfiguration.self, from: data) else {
            return .default
        }
        return configuration
    }

    func save(_ configuration: ProviderConfiguration) throws {
        // 该 Codable 模型刻意不包含 API Key，因此 UserDefaults 只保存非敏感的连接元数据。
        defaults.set(try encoder.encode(configuration), forKey: storageKey)
    }
}
