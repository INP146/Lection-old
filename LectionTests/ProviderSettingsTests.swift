import Foundation
import Security
import Testing
@testable import Lection

@Suite("Provider configuration")
@MainActor
struct ProviderConfigurationTests {
    @Test("Non-sensitive configuration survives store recreation")
    func configurationPersistsWithoutAPIKey() throws {
        let suiteName = "ProviderConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = try ProviderConfiguration.validated(
            baseURLText: "https://example.com/openai/v1",
            modelName: "example-model",
            requestTimeout: 90,
            supportsJSONSchema: false,
            supportsJSONObject: true
        )
        try UserDefaultsProviderConfigurationStore(defaults: defaults).save(configuration)

        let reopenedStore = UserDefaultsProviderConfigurationStore(defaults: defaults)
        #expect(reopenedStore.load() == configuration)

        let persistedText = String(describing: defaults.dictionaryRepresentation())
        #expect(!persistedText.contains("test-secret-api-key"))
    }

    @Test("Local network HTTP is allowed")
    func localHTTPValidation() throws {
        let allowedURLs = [
            "http://192.168.1.20:11434/v1",
            "http://10.0.0.8/v1",
            "http://172.16.1.5/v1",
            "http://localhost:8080/v1",
            "http://modelbox.local/v1",
            "http://modelbox/v1",
            "http://[fd00::1]:8080/v1",
            "http://[fe80::1]:8080/v1",
        ]

        for baseURL in allowedURLs {
            let configuration = try validatedConfiguration(baseURL: baseURL)
            #expect(configuration.baseURL.absoluteString == baseURL)
        }
    }

    @Test("Public HTTP and malformed URLs are rejected")
    func publicHTTPValidation() {
        #expect(throws: ProviderConfigurationError.insecurePublicBaseURL) {
            try validatedConfiguration(baseURL: "http://example.com/v1")
        }

        #expect(throws: ProviderConfigurationError.insecurePublicBaseURL) {
            try validatedConfiguration(baseURL: "http://8.8.8.8/v1")
        }

        #expect(throws: ProviderConfigurationError.invalidBaseURL) {
            try validatedConfiguration(baseURL: "https:///v1")
        }
    }

    private func validatedConfiguration(baseURL: String) throws -> ProviderConfiguration {
        try ProviderConfiguration.validated(
            baseURLText: baseURL,
            modelName: "model",
            requestTimeout: 60,
            supportsJSONSchema: true,
            supportsJSONObject: true
        )
    }
}

@Suite("Keychain API key", .serialized)
struct KeychainStoreTests {
    @Test("API key can be saved, replaced, and deleted")
    func keyLifecycle() throws {
        let store = KeychainStore(
            service: "com.lection.tests.\(UUID().uuidString)",
            account: "api-key"
        )
        defer { try? store.deleteAPIKey() }

        #expect(try store.loadAPIKey() == nil)

        try store.saveAPIKey("first-key")
        #expect(try store.loadAPIKey() == "first-key")
        #expect(try accessibility(for: store) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        try store.saveAPIKey("replacement-key")
        #expect(try store.loadAPIKey() == "replacement-key")

        try store.deleteAPIKey()
        #expect(try store.loadAPIKey() == nil)
    }

    private func accessibility(for store: KeychainStore) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: store.service,
            kSecAttrAccount: store.account,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(status)
        }
        return (result as? [CFString: Any])?[kSecAttrAccessible] as? String
    }
}

@Suite("Provider connection testing")
struct ProviderConnectionTesterTests {
    @Test("Successful Models response verifies the configured model")
    func successfulConnection() async throws {
        let loader = StubHTTPDataLoader(
            data: Data(#"{"data":[{"id":"test-model"}]}"#.utf8),
            statusCode: 200
        )
        let tester = OpenAICompatibleConnectionTester(dataLoader: loader)

        try await tester.testConnection(
            configuration: try configuration(),
            apiKey: "secret-key"
        )

        let request = await loader.lastRequest
        #expect(request?.url?.absoluteString == "https://example.com/v1/models")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
    }

    @Test("Authentication failures are classified")
    func invalidAPIKey() async throws {
        let tester = OpenAICompatibleConnectionTester(
            dataLoader: StubHTTPDataLoader(data: Data(), statusCode: 401)
        )
        let error = await connectionError(from: tester)
        #expect(error == .invalidAPIKey)
    }

    @Test("A missing configured model is classified")
    func missingModel() async throws {
        let tester = OpenAICompatibleConnectionTester(
            dataLoader: StubHTTPDataLoader(
                data: Data(#"{"data":[{"id":"another-model"}]}"#.utf8),
                statusCode: 200
            )
        )
        let error = await connectionError(from: tester)
        #expect(error == .modelNotFound("test-model"))
    }

    @Test("Malformed responses are classified")
    func malformedResponse() async throws {
        let tester = OpenAICompatibleConnectionTester(
            dataLoader: StubHTTPDataLoader(data: Data("not-json".utf8), statusCode: 200)
        )
        let error = await connectionError(from: tester)
        #expect(error == .invalidResponseFormat)
    }

    @Test("Transport failures are classified")
    func networkFailure() async throws {
        let tester = OpenAICompatibleConnectionTester(
            dataLoader: StubHTTPDataLoader(errorCode: .notConnectedToInternet)
        )
        let error = await connectionError(from: tester)
        #expect(error == .network(.notConnectedToInternet))
    }

    private func configuration() throws -> ProviderConfiguration {
        try ProviderConfiguration.validated(
            baseURLText: "https://example.com/v1",
            modelName: "test-model",
            requestTimeout: 60,
            supportsJSONSchema: true,
            supportsJSONObject: true
        )
    }

    private func connectionError(
        from tester: OpenAICompatibleConnectionTester
    ) async -> ProviderConnectionError? {
        do {
            try await tester.testConnection(
                configuration: try configuration(),
                apiKey: "secret-key"
            )
            return nil
        } catch let error as ProviderConnectionError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }
}

private actor StubHTTPDataLoader: HTTPDataLoading {
    private let data: Data
    private let statusCode: Int?
    private let errorCode: URLError.Code?
    private(set) var lastRequest: URLRequest?

    init(data: Data = Data(), statusCode: Int? = nil, errorCode: URLError.Code? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.errorCode = errorCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request

        if let errorCode {
            throw URLError(errorCode)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode ?? 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}
