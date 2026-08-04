import Foundation
import Observation

@Observable
@MainActor
final class ProviderSettings {
    enum Operation: Equatable {
        case idle
        case saving
        case testing
        case success(String)
        case failure(String)
    }

    var baseURLText: String
    var modelName: String
    var requestTimeout: TimeInterval
    var supportsJSONSchema: Bool
    var supportsJSONObject: Bool
    var apiKeyInput = ""
    var hasSavedAPIKey: Bool
    var operation: Operation = .idle

    private let configurationStore: any ProviderConfigurationPersisting
    private let keychainStore: any APIKeyStoring
    private let connectionTester: any ProviderConnectionTesting

    init(
        configurationStore: any ProviderConfigurationPersisting = UserDefaultsProviderConfigurationStore(),
        keychainStore: any APIKeyStoring = KeychainStore.apiKey,
        connectionTester: any ProviderConnectionTesting = OpenAICompatibleConnectionTester()
    ) {
        self.configurationStore = configurationStore
        self.keychainStore = keychainStore
        self.connectionTester = connectionTester

        let configuration = configurationStore.load()
        baseURLText = configuration.baseURL.absoluteString
        modelName = configuration.modelName
        requestTimeout = configuration.requestTimeout
        supportsJSONSchema = configuration.supportsJSONSchema
        supportsJSONObject = configuration.supportsJSONObject

        do {
            hasSavedAPIKey = try keychainStore.loadAPIKey() != nil
        } catch {
            hasSavedAPIKey = false
            operation = .failure(error.localizedDescription)
        }
    }

    var isBusy: Bool {
        operation == .saving || operation == .testing
    }

    func save() {
        operation = .saving

        do {
            let configuration = try makeConfiguration()
            let newAPIKey = normalizedAPIKeyInput

            guard !newAPIKey.isEmpty || hasSavedAPIKey else {
                throw KeychainStoreError.invalidAPIKey
            }

            if !newAPIKey.isEmpty {
                try keychainStore.saveAPIKey(newAPIKey)
                hasSavedAPIKey = true
                apiKeyInput = ""
            }

            try configurationStore.save(configuration)
            apply(configuration)
            operation = .success("配置已保存。")
        } catch {
            operation = .failure(error.localizedDescription)
        }
    }

    func deleteAPIKey() {
        do {
            try keychainStore.deleteAPIKey()
            apiKeyInput = ""
            hasSavedAPIKey = false
            operation = .success("API Key 已删除。")
        } catch {
            operation = .failure(error.localizedDescription)
        }
    }

    func testConnection() async {
        operation = .testing

        do {
            let configuration = try makeConfiguration()
            let inputAPIKey = normalizedAPIKeyInput
            let apiKey = if !inputAPIKey.isEmpty {
                inputAPIKey
            } else if let storedAPIKey = try keychainStore.loadAPIKey() {
                storedAPIKey
            } else {
                throw KeychainStoreError.invalidAPIKey
            }

            try await connectionTester.testConnection(
                configuration: configuration,
                apiKey: apiKey
            )
            operation = .success("连接成功，模型可用。")
        } catch is CancellationError {
            operation = .idle
        } catch {
            operation = .failure(error.localizedDescription)
        }
    }

    private var normalizedAPIKeyInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeConfiguration() throws -> ProviderConfiguration {
        try ProviderConfiguration.validated(
            baseURLText: baseURLText,
            modelName: modelName,
            requestTimeout: requestTimeout,
            supportsJSONSchema: supportsJSONSchema,
            supportsJSONObject: supportsJSONObject
        )
    }

    private func apply(_ configuration: ProviderConfiguration) {
        baseURLText = configuration.baseURL.absoluteString
        modelName = configuration.modelName
        requestTimeout = configuration.requestTimeout
        supportsJSONSchema = configuration.supportsJSONSchema
        supportsJSONObject = configuration.supportsJSONObject
    }
}
