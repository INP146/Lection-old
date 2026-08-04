import Foundation

protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPDataLoader: HTTPDataLoading, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

protocol ProviderConnectionTesting: Sendable {
    func testConnection(
        configuration: ProviderConfiguration,
        apiKey: String
    ) async throws
}

struct OpenAICompatibleConnectionTester: ProviderConnectionTesting, Sendable {
    private let dataLoader: any HTTPDataLoading

    init(dataLoader: any HTTPDataLoading = URLSessionHTTPDataLoader()) {
        self.dataLoader = dataLoader
    }

    func testConnection(
        configuration: ProviderConfiguration,
        apiKey: String
    ) async throws {
        let modelsURL = configuration.baseURL.appending(path: "models")
        var request = URLRequest(
            url: modelsURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw ProviderConnectionError.network(error.code)
        } catch {
            throw ProviderConnectionError.network(.unknown)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderConnectionError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let response: ModelsResponse
            do {
                response = try JSONDecoder().decode(ModelsResponse.self, from: data)
            } catch {
                // 这里只保留错误类别，不记录响应正文，避免供应商返回的内容进入日志。
                throw ProviderConnectionError.invalidResponseFormat
            }

            guard response.data.contains(where: { $0.id == configuration.modelName }) else {
                throw ProviderConnectionError.modelNotFound(configuration.modelName)
            }
        case 401, 403:
            throw ProviderConnectionError.invalidAPIKey
        default:
            throw ProviderConnectionError.server(statusCode: httpResponse.statusCode)
        }
    }
}

enum ProviderConnectionError: LocalizedError, Equatable, Sendable {
    case invalidAPIKey
    case modelNotFound(String)
    case network(URLError.Code)
    case invalidResponse
    case invalidResponseFormat
    case server(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "API Key 无效或没有访问权限。"
        case let .modelNotFound(modelName):
            "服务可连接，但没有找到模型“\(modelName)”。"
        case .network:
            "网络连接失败，请检查网络和 Base URL。"
        case .invalidResponse:
            "服务返回了无法识别的响应。"
        case .invalidResponseFormat:
            "服务响应格式与 OpenAI-compatible Models API 不兼容。"
        case let .server(statusCode):
            "服务返回 HTTP \(statusCode)，请检查 Base URL 或稍后重试。"
        }
    }
}

private struct ModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}
