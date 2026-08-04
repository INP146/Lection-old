import Foundation
import Security

protocol APIKeyStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

struct KeychainStore: APIKeyStoring, Sendable {
    static let apiKey = KeychainStore(
        service: "com.lection.app.ai-provider",
        account: "default-api-key"
    )

    let service: String
    let account: String

    func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let apiKey = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.invalidStoredValue
            }
            return apiKey
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    func saveAPIKey(_ apiKey: String) throws {
        guard !apiKey.isEmpty, let data = apiKey.data(using: .utf8) else {
            throw KeychainStoreError.invalidAPIKey
        }

        // 先更新已有条目，使“保存”天然支持替换密钥；不存在时再创建。
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecValueData] = data
            // 密钥只能在设备已解锁时访问，并且不会迁移到另一台设备。
            attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainStoreError.unhandledStatus(updateStatus)
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandledStatus(status)
        }
    }

    private var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}

enum KeychainStoreError: LocalizedError, Equatable {
    case invalidAPIKey
    case invalidStoredValue
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "API Key 不能为空。"
        case .invalidStoredValue:
            "Keychain 中的 API Key 格式无效。"
        case let .unhandledStatus(status):
            "无法访问 Keychain（错误码：\(status)）。"
        }
    }
}
