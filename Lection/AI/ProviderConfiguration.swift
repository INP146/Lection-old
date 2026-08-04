import Foundation
import Network

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
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let baseURL = components.url else {
            // 禁止凭据、查询参数和片段进入 Base URL，避免后续拼接接口路径时泄漏或产生歧义。
            throw ProviderConfigurationError.invalidBaseURL
        }

        switch scheme {
        case "https":
            break
        case "http" where LocalNetworkHost.contains(host):
            // 局域网模型服务经常没有 TLS；只对可明确识别的本地地址开放明文 HTTP。
            break
        case "http":
            throw ProviderConfigurationError.insecurePublicBaseURL
        default:
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
    case insecurePublicBaseURL
    case missingModelName
    case invalidRequestTimeout

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Base URL 必须是有效的 HTTP 或 HTTPS 地址，且不能包含账号、查询参数或片段。"
        case .insecurePublicBaseURL:
            "公网 Base URL 必须使用 HTTPS；HTTP 仅限局域网或本机地址。"
        case .missingModelName:
            "请输入模型名称。"
        case .invalidRequestTimeout:
            "请求超时时间必须在 15 到 180 秒之间。"
        }
    }
}

private enum LocalNetworkHost {
    static func contains(_ host: String) -> Bool {
        let addressHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if let address = IPv4Address(addressHost) {
            return isPrivateOrLocalIPv4([UInt8](address.rawValue))
        }

        if let address = IPv6Address(addressHost) {
            return isPrivateOrLocalIPv6([UInt8](address.rawValue))
        }

        let dnsHost = addressHost.hasSuffix(".")
            ? String(addressHost.dropLast())
            : addressHost
        return dnsHost == "localhost"
            || dnsHost.hasSuffix(".localhost")
            || dnsHost.hasSuffix(".local")
            || !dnsHost.contains(".")
    }

    private static func isPrivateOrLocalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }

        return bytes[0] == 10
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || bytes[0] == 127
            || (bytes[0] == 169 && bytes[1] == 254)
    }

    private static func isPrivateOrLocalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isUniqueLocal = bytes[0] & 0xFE == 0xFC
        let isLinkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
        return isLoopback || isUniqueLocal || isLinkLocal
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
