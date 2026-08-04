import Foundation
import Testing
@testable import Lection

@Suite("OpenAI-compatible provider")
struct OpenAICompatibleProviderTests {
    private let paragraphID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let optionIDs = [
        UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
        UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
        UUID(uuidString: "40000000-0000-0000-0000-000000000003")!,
    ]

    @Test("Provider sends JSON Schema and returns a validated article")
    func generatesArticle() async throws {
        let article = validArticle
        let loader = QueuedHTTPDataLoader(outcomes: [
            .response(try completionData(article), statusCode: 200),
        ])
        let provider = makeProvider(dataLoader: loader)

        let result = try await provider.generateArticle(request: articleRequest)
        #expect(result == article)

        let request = try #require(await loader.requests.first)
        #expect(request.url?.absoluteString == "https://example.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")

        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let responseFormat = try #require(object["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        #expect(jsonSchema["strict"] as? Bool == true)
    }

    @Test("Question and translation responses are decoded and validated")
    func decodesAllTaskTypes() async throws {
        let questionEnvelope = GeneratedQuestionEnvelope(questions: [validQuestion])
        let translationEnvelope = ParagraphTranslationEnvelope(
            translations: [.init(paragraphID: paragraphID, translatedText: "火车在夜间运行。")]
        )
        let loader = QueuedHTTPDataLoader(outcomes: [
            .response(try completionData(questionEnvelope), statusCode: 200),
            .response(try completionData(translationEnvelope), statusCode: 200),
        ])
        let provider = makeProvider(dataLoader: loader)

        let questions = try await provider.generateQuestions(request: questionRequest)
        let translations = try await provider.translateParagraphs(request: translationRequest)

        #expect(questions == [validQuestion])
        #expect(translations == translationEnvelope.translations)
    }

    @Test("Invalid output is repaired at most once")
    func repairsInvalidOutputOnce() async throws {
        let loader = QueuedHTTPDataLoader(outcomes: [
            .response(try completionData(content: "not-json"), statusCode: 200),
            .response(try completionData(validArticle), statusCode: 200),
        ])
        let provider = makeProvider(dataLoader: loader)

        let article = try await provider.generateArticle(request: articleRequest)
        #expect(article == validArticle)
        #expect(await loader.requests.count == 2)

        let secondBody = try #require(await loader.requests.last?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let userMessage = try #require(messages.last?["content"] as? String)
        #expect(userMessage.contains("previous response was invalid"))
    }

    @Test("Output repair stops after the configured limit")
    func repairLimit() async throws {
        let loader = QueuedHTTPDataLoader(outcomes: [
            .response(try completionData(content: "invalid-one"), statusCode: 200),
            .response(try completionData(content: "invalid-two"), statusCode: 200),
        ])
        let provider = makeProvider(dataLoader: loader)

        let error = await providerError {
            try await provider.generateArticle(request: articleRequest)
        }
        #expect(error == .outputDecodingFailed)
        #expect(await loader.requests.count == 2)
    }

    @Test("HTTP and supplier errors are classified without exposing the key")
    func mapsHTTPErrors() async throws {
        let cases: [(Int, String, AIProviderError)] = [
            (401, #"{"error":{"message":"bad key","type":"authentication_error","code":"invalid_api_key"}}"#, .invalidAPIKey),
            (404, #"{"error":{"message":"missing","type":"invalid_request_error","code":"model_not_found"}}"#, .modelNotFound),
            (429, #"{"error":{"message":"slow down","type":"rate_limit_error","code":"rate_limit"}}"#, .rateLimited),
            (500, #"{"error":{"message":"failure secret-key\nretry","type":"server_error","code":"server"}}"#, .server(statusCode: 500, message: "failure [REDACTED] retry")),
        ]

        for (statusCode, body, expectedError) in cases {
            let loader = QueuedHTTPDataLoader(outcomes: [
                .response(Data(body.utf8), statusCode: statusCode),
            ])
            let provider = makeProvider(dataLoader: loader, repairAttempts: 0)
            let error = await providerError {
                try await provider.generateArticle(request: articleRequest)
            }
            #expect(error == expectedError)
        }
    }

    @Test("Timeout and cancellation keep distinct semantics")
    func mapsTransportErrors() async throws {
        let timeoutProvider = makeProvider(
            dataLoader: QueuedHTTPDataLoader(outcomes: [.urlError(.timedOut)]),
            repairAttempts: 0
        )
        let timeoutError = await providerError {
            try await timeoutProvider.generateArticle(request: articleRequest)
        }
        #expect(timeoutError == .timeout)

        let cancelledProvider = makeProvider(
            dataLoader: QueuedHTTPDataLoader(outcomes: [.urlError(.cancelled)]),
            repairAttempts: 0
        )
        do {
            _ = try await cancelledProvider.generateArticle(request: articleRequest)
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // CancellationError 会被上层 Task 和 Pipeline 按取消处理，而不是显示成网络失败。
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Response format follows provider capabilities")
    func responseFormatFallbacks() async throws {
        let capabilityCases: [(Bool, Bool, String?)] = [
            (true, true, "json_schema"),
            (false, true, "json_object"),
            (false, false, nil),
        ]

        for (supportsSchema, supportsObject, expectedType) in capabilityCases {
            let loader = QueuedHTTPDataLoader(outcomes: [
                .response(try completionData(validArticle), statusCode: 200),
            ])
            let provider = makeProvider(
                configuration: configuration(
                    supportsJSONSchema: supportsSchema,
                    supportsJSONObject: supportsObject
                ),
                dataLoader: loader
            )
            _ = try await provider.generateArticle(request: articleRequest)

            let body = try #require(await loader.requests.first?.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let responseFormat = object["response_format"] as? [String: Any]
            #expect(responseFormat?["type"] as? String == expectedType)
            #expect((object["response_format"] == nil) == (expectedType == nil))
        }
    }

    @Test("Invalid constraints fail before any network request")
    func rejectsInvalidRequestsLocally() async throws {
        let loader = QueuedHTTPDataLoader(outcomes: [])
        let provider = makeProvider(dataLoader: loader)
        let invalidRequest = ArticleGenerationRequest(
            prompt: prompt,
            minimumParagraphCount: 3,
            maximumParagraphCount: 2
        )

        let error = await providerError {
            try await provider.generateArticle(request: invalidRequest)
        }

        guard case .invalidRequest = error else {
            Issue.record("Expected invalid request error")
            return
        }
        #expect(await loader.requests.isEmpty)
    }

    @Test("Mock provider exposes all required deterministic scenarios")
    func mockScenarios() async throws {
        let fixtures = MockAIProvider.Fixtures(
            article: validArticle,
            questions: [validQuestion],
            translations: [.init(paragraphID: paragraphID, translatedText: "译文")]
        )

        let success = MockAIProvider(scenario: .success(fixtures))
        #expect(try await success.generateArticle(request: articleRequest) == validArticle)

        let timeout = MockAIProvider(scenario: .timeout)
        let timeoutError = await providerError {
            try await timeout.generateArticle(request: articleRequest)
        }
        #expect(timeoutError == .timeout)

        let invalidJSON = MockAIProvider(scenario: .invalidJSON)
        let decodingError = await providerError {
            try await invalidJSON.generateArticle(request: articleRequest)
        }
        #expect(decodingError == .outputDecodingFailed)

        let partialFixtures = MockAIProvider.Fixtures(
            article: validArticle,
            questions: [validQuestion],
            translations: []
        )
        let partial = MockAIProvider(scenario: .partialTranslation(partialFixtures))
        let partialError = await providerError {
            try await partial.translateParagraphs(request: translationRequest)
        }
        guard case let .validationFailed(issues) = partialError else {
            Issue.record("Expected missing translation validation error")
            return
        }
        #expect(issues.contains(where: { $0.code == .missingTranslation }))
    }

    private var prompt: AIRequestPrompt {
        .init(system: "Return structured content.", user: "Create the requested content.")
    }

    private var articleRequest: ArticleGenerationRequest {
        .init(prompt: prompt, minimumParagraphCount: 1, maximumParagraphCount: 2)
    }

    private var questionRequest: QuestionGenerationRequest {
        .init(
            prompt: prompt,
            sourceParagraphs: [.init(id: paragraphID, text: "A train runs at night.")],
            expectedQuestionCount: 1
        )
    }

    private var translationRequest: TranslationRequest {
        .init(
            prompt: prompt,
            sourceParagraphs: [.init(id: paragraphID, text: "A train runs at night.")],
            targetLanguage: "zh-Hans"
        )
    }

    private var validArticle: GeneratedArticle {
        .init(
            title: "Night Train",
            paragraphs: [.init(id: paragraphID, text: "A train runs at night.")]
        )
    }

    private var validQuestion: GeneratedQuestion {
        .init(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            stem: "When does the train run?",
            options: [
                .init(id: optionIDs[0], text: "At night"),
                .init(id: optionIDs[1], text: "At noon"),
                .init(id: optionIDs[2], text: "At dawn"),
            ],
            correctOptionID: optionIDs[0],
            explanation: "The paragraph explicitly says it runs at night.",
            evidenceParagraphIDs: [paragraphID]
        )
    }

    private func configuration(
        supportsJSONSchema: Bool = true,
        supportsJSONObject: Bool = true
    ) -> ProviderConfiguration {
        .init(
            baseURL: URL(string: "https://example.com/v1")!,
            modelName: "test-model",
            requestTimeout: 60,
            supportsJSONSchema: supportsJSONSchema,
            supportsJSONObject: supportsJSONObject
        )
    }

    private func makeProvider(
        configuration: ProviderConfiguration? = nil,
        dataLoader: any HTTPDataLoading,
        repairAttempts: Int = 1
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            configuration: configuration ?? self.configuration(),
            apiKey: "secret-key",
            dataLoader: dataLoader,
            maximumOutputRepairAttempts: repairAttempts
        )
    }

    private func completionData<Value: Encodable>(_ value: Value) throws -> Data {
        let content = try #require(String(data: JSONEncoder().encode(value), encoding: .utf8))
        return try completionData(content: content)
    }

    private func completionData(content: String) throws -> Data {
        try JSONEncoder().encode(
            TestChatCompletionResponse(
                choices: [.init(message: .init(content: content))]
            )
        )
    }

    private func providerError<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async -> AIProviderError? {
        do {
            _ = try await operation()
            return nil
        } catch let error as AIProviderError {
            return error
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }
}

private struct TestChatCompletionResponse: Encodable {
    let choices: [Choice]

    struct Choice: Encodable {
        let message: Message
    }

    struct Message: Encodable {
        let content: String
    }
}

private actor QueuedHTTPDataLoader: HTTPDataLoading {
    enum Outcome: Sendable {
        case response(Data, statusCode: Int)
        case urlError(URLError.Code)
    }

    private var outcomes: [Outcome]
    private(set) var requests: [URLRequest] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw URLError(.badServerResponse)
        }

        switch outcomes.removeFirst() {
        case let .response(data, statusCode):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, response)
        case let .urlError(code):
            throw URLError(code)
        }
    }
}
