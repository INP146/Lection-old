import Foundation

struct OpenAICompatibleProvider: AIProvider, Sendable {
    private let configuration: ProviderConfiguration
    private let apiKey: String
    private let dataLoader: any HTTPDataLoading
    private let maximumOutputRepairAttempts: Int

    init(
        configuration: ProviderConfiguration,
        apiKey: String,
        dataLoader: any HTTPDataLoading = URLSessionHTTPDataLoader(),
        maximumOutputRepairAttempts: Int = 1
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.dataLoader = dataLoader
        // 第一阶段最多自动修复一次，避免 BYOK 场景下无上限地产生费用。
        self.maximumOutputRepairAttempts = min(max(maximumOutputRepairAttempts, 0), 1)
    }

    func generateArticle(
        request: ArticleGenerationRequest
    ) async throws -> GeneratedArticle {
        guard request.minimumParagraphCount > 0,
              request.maximumParagraphCount >= request.minimumParagraphCount else {
            throw AIProviderError.invalidRequest("文章段落数量约束无效。")
        }

        return try await performStructuredRequest(
            prompt: request.prompt,
            schemaName: "generated_article",
            schema: ResponseSchemas.article(
                minimumParagraphCount: request.minimumParagraphCount,
                maximumParagraphCount: request.maximumParagraphCount
            )
        ) { content in
            let article = try StructuredResponseDecoder.decode(GeneratedArticle.self, from: content)
            try AIResponseValidator.validate(article: article, for: request)
            return article
        }
    }

    func generateQuestions(
        request: QuestionGenerationRequest
    ) async throws -> [GeneratedQuestion] {
        try validateSourceParagraphs(request.sourceParagraphs)
        guard request.expectedQuestionCount > 0 else {
            throw AIProviderError.invalidRequest("题目数量必须大于零。")
        }

        return try await performStructuredRequest(
            prompt: request.prompt,
            schemaName: "generated_questions",
            schema: ResponseSchemas.questions(expectedCount: request.expectedQuestionCount)
        ) { content in
            let envelope = try StructuredResponseDecoder.decode(
                GeneratedQuestionEnvelope.self,
                from: content
            )
            try AIResponseValidator.validate(questions: envelope.questions, for: request)
            return envelope.questions
        }
    }

    func translateParagraphs(
        request: TranslationRequest
    ) async throws -> [ParagraphTranslation] {
        try validateSourceParagraphs(request.sourceParagraphs)
        guard !request.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidRequest("目标翻译语言不能为空。")
        }

        return try await performStructuredRequest(
            prompt: request.prompt,
            schemaName: "paragraph_translations",
            schema: ResponseSchemas.translations(expectedCount: request.sourceParagraphs.count)
        ) { content in
            let envelope = try StructuredResponseDecoder.decode(
                ParagraphTranslationEnvelope.self,
                from: content
            )
            try AIResponseValidator.validate(translations: envelope.translations, for: request)
            return envelope.translations
        }
    }

    private func performStructuredRequest<Response: Sendable>(
        prompt: AIRequestPrompt,
        schemaName: String,
        schema: JSONValue,
        decodeAndValidate: @Sendable (String) throws -> Response
    ) async throws -> Response {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidRequest("尚未配置 API Key。")
        }
        guard !configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidRequest("尚未配置模型名称。")
        }
        guard !prompt.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidRequest("模型请求内容不能为空。")
        }

        var currentPrompt = prompt
        for attempt in 0...maximumOutputRepairAttempts {
            let content = try await requestCompletion(
                prompt: currentPrompt,
                schemaName: schemaName,
                schema: schema
            )

            do {
                return try decodeAndValidate(content)
            } catch let error as AIProviderError {
                let canRepair = switch error {
                case .outputDecodingFailed, .validationFailed:
                    true
                default:
                    false
                }

                guard canRepair, attempt < maximumOutputRepairAttempts else {
                    throw error
                }
                currentPrompt = prompt.appendingOutputRepairInstruction()
            }
        }

        throw AIProviderError.outputDecodingFailed
    }

    private func validateSourceParagraphs(_ paragraphs: [SourceParagraph]) throws {
        guard !paragraphs.isEmpty else {
            throw AIProviderError.invalidRequest("原文段落不能为空。")
        }
        guard Set(paragraphs.map(\.id)).count == paragraphs.count else {
            throw AIProviderError.invalidRequest("原文段落 ID 不能重复。")
        }
        guard paragraphs.allSatisfy({
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw AIProviderError.invalidRequest("原文段落内容不能为空。")
        }
    }

    private func requestCompletion(
        prompt: AIRequestPrompt,
        schemaName: String,
        schema: JSONValue
    ) async throws -> String {
        try Task.checkCancellation()

        let endpoint = configuration.baseURL.appending(path: "chat/completions")
        let payload = ChatCompletionsRequest(
            model: configuration.modelName,
            messages: [
                .init(role: "system", content: prompt.system),
                .init(role: "user", content: prompt.user),
            ],
            responseFormat: responseFormat(schemaName: schemaName, schema: schema)
        )

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw AIProviderError.invalidRequest("无法编码模型请求。")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw AIProviderError.timeout
            default:
                throw AIProviderError.network(error.code)
            }
        } catch {
            throw AIProviderError.network(.unknown)
        }

        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
        }

        let completionResponse: ChatCompletionsResponse
        do {
            completionResponse = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        } catch {
            throw AIProviderError.invalidProviderResponse
        }

        guard let content = completionResponse.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyResponse
        }
        return content
    }

    private func responseFormat(schemaName: String, schema: JSONValue) -> ChatResponseFormat? {
        if configuration.supportsJSONSchema {
            return .jsonSchema(name: schemaName, schema: schema)
        }
        if configuration.supportsJSONObject {
            return .jsonObject
        }
        return nil
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> AIProviderError {
        let payload = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data).error
        let code = payload?.code?.lowercased() ?? ""
        let type = payload?.type?.lowercased() ?? ""
        let message = sanitizedProviderMessage(payload?.message)

        if statusCode == 401 || statusCode == 403 {
            return .invalidAPIKey
        }
        if code.contains("model_not_found")
            || type.contains("model_not_found")
            || (statusCode == 404 && (code.contains("model") || type.contains("model"))) {
            return .modelNotFound
        }
        if statusCode == 408 {
            return .timeout
        }
        if statusCode == 429 {
            return .rateLimited
        }
        return .server(statusCode: statusCode, message: message)
    }

    private func sanitizedProviderMessage(_ message: String?) -> String? {
        guard let message else { return nil }

        let redacted = message.replacingOccurrences(of: apiKey, with: "[REDACTED]")
        let singleLine = redacted
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return nil }
        return String(singleLine.prefix(240))
    }
}

private struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [Message]
    let responseFormat: ChatResponseFormat?

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
    }
}

private struct ChatResponseFormat: Encodable {
    let type: String
    let jsonSchema: SchemaEnvelope?

    static func jsonSchema(name: String, schema: JSONValue) -> ChatResponseFormat {
        ChatResponseFormat(
            type: "json_schema",
            jsonSchema: .init(name: name, strict: true, schema: schema)
        )
    }

    static let jsonObject = ChatResponseFormat(type: "json_object", jsonSchema: nil)

    struct SchemaEnvelope: Encodable {
        let name: String
        let strict: Bool
        let schema: JSONValue
    }

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct ProviderErrorEnvelope: Decodable {
    let error: Payload

    struct Payload: Decodable {
        let message: String?
        let type: String?
        let code: LossyString?
    }
}

private struct LossyString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int.self) {
            value = String(integer)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer")
            )
        }
    }

    func lowercased() -> String {
        value.lowercased()
    }
}

private indirect enum JSONValue: Encodable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        }
    }

    static func schemaObject(
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .boolean(false),
        ])
    }

    static func schemaArray(
        items: JSONValue,
        minimumCount: Int? = nil,
        maximumCount: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("array"),
            "items": items,
        ]
        if let minimumCount {
            schema["minItems"] = .integer(minimumCount)
        }
        if let maximumCount {
            schema["maxItems"] = .integer(maximumCount)
        }
        return .object(schema)
    }

    static let schemaString: JSONValue = .object(["type": .string("string")])
    static let schemaUUID: JSONValue = .object([
        "type": .string("string"),
        "format": .string("uuid"),
    ])
}

private enum ResponseSchemas {
    static func article(
        minimumParagraphCount: Int,
        maximumParagraphCount: Int
    ) -> JSONValue {
        .schemaObject(
            properties: [
                "title": .schemaString,
                "paragraphs": .schemaArray(
                    items: .schemaObject(
                        properties: [
                            "id": .schemaUUID,
                            "text": .schemaString,
                        ],
                        required: ["id", "text"]
                    ),
                    minimumCount: minimumParagraphCount,
                    maximumCount: maximumParagraphCount
                ),
            ],
            required: ["title", "paragraphs"]
        )
    }

    static func questions(expectedCount: Int) -> JSONValue {
        let option = JSONValue.schemaObject(
            properties: [
                "id": .schemaUUID,
                "text": .schemaString,
            ],
            required: ["id", "text"]
        )
        let question = JSONValue.schemaObject(
            properties: [
                "id": .schemaUUID,
                "stem": .schemaString,
                "options": .schemaArray(items: option, minimumCount: 3),
                "correctOptionID": .schemaUUID,
                "explanation": .schemaString,
                "evidenceParagraphIDs": .schemaArray(items: .schemaUUID, minimumCount: 1),
            ],
            required: [
                "id",
                "stem",
                "options",
                "correctOptionID",
                "explanation",
                "evidenceParagraphIDs",
            ]
        )
        return .schemaObject(
            properties: [
                "questions": .schemaArray(
                    items: question,
                    minimumCount: expectedCount,
                    maximumCount: expectedCount
                ),
            ],
            required: ["questions"]
        )
    }

    static func translations(expectedCount: Int) -> JSONValue {
        let translation = JSONValue.schemaObject(
            properties: [
                "paragraphID": .schemaUUID,
                "translatedText": .schemaString,
            ],
            required: ["paragraphID", "translatedText"]
        )
        return .schemaObject(
            properties: [
                "translations": .schemaArray(
                    items: translation,
                    minimumCount: expectedCount,
                    maximumCount: expectedCount
                ),
            ],
            required: ["translations"]
        )
    }
}
