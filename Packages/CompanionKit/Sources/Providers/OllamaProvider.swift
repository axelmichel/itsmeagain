import CompanionCore
import Foundation

/// Talks to a local (or LAN) Ollama server via its native `/api/*` endpoints.
public struct OllamaProvider: LLMProvider, Embedder {
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    public let id: ProviderID
    public let displayName: String
    public let baseURL: URL
    public let embeddingModel: String
    public var capabilities: ProviderCapabilities { [.streaming, .tools, .thinking, .embeddings, .vision] }

    private let session: URLSession

    public init(
        id: ProviderID = .ollama,
        displayName: String = "Ollama",
        baseURL: URL = OllamaProvider.defaultBaseURL,
        embeddingModel: String = "embeddinggemma",
        session: URLSession = .shared
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.embeddingModel = embeddingModel
        self.session = session
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        let url = baseURL.appending(path: "api/tags")
        let (data, response) = try await load(URLRequest(url: url))
        try HTTP.validate(response, body: data)
        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        return tags.models
            .map { model in
                let details = [model.details?.parameterSize, model.details?.quantizationLevel]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return ModelInfo(id: model.name, sizeBytes: model.size, details: details.isEmpty ? nil : details)
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: Chat

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appending(path: "api/chat")
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONEncoder().encode(ChatBody(request))

                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await session.bytes(for: urlRequest)
                    } catch {
                        throw HTTP.mapConnectionError(error, service: "Ollama", url: baseURL)
                    }
                    try await HTTP.validate(response, bytes: bytes)

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines where !line.isEmpty {
                        let chunk = try decoder.decode(ChatChunk.self, from: Data(line.utf8))
                        if let error = chunk.error { throw ProviderError.server(error) }
                        if let message = chunk.message {
                            if let thinking = message.thinking, !thinking.isEmpty {
                                continuation.yield(.thinkingDelta(thinking))
                            }
                            if !message.content.isEmpty {
                                continuation.yield(.textDelta(message.content))
                            }
                            for call in message.toolCalls ?? [] {
                                continuation.yield(.toolCall(ToolCall(
                                    id: call.id ?? UUID().uuidString,
                                    name: call.function.name,
                                    arguments: call.function.arguments
                                )))
                            }
                        }
                        if chunk.done == true {
                            continuation.yield(.done(Usage(
                                promptTokens: chunk.promptEvalCount,
                                completionTokens: chunk.evalCount
                            )))
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Embeddings

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        var urlRequest = URLRequest(url: baseURL.appending(path: "api/embed"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(EmbedBody(model: embeddingModel, input: texts))
        let (data, response) = try await load(urlRequest)
        try HTTP.validate(response, body: data)
        return try JSONDecoder().decode(EmbedResponse.self, from: data).embeddings
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw HTTP.mapConnectionError(error, service: "Ollama", url: baseURL)
        }
    }
}

// MARK: - Wire format

extension OllamaProvider {
    struct ChatBody: Encodable {
        var model: String
        var messages: [Message]
        var stream = true
        var tools: [Tool]?
        var options: Options?
        var keepAlive: String?
        var think: Bool?
        var format: JSONValue?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, tools, options, think, format
            case keepAlive = "keep_alive"
        }

        init(_ request: ChatRequest) {
            model = request.model
            var messages: [Message] = []
            if let system = request.system, !system.isEmpty {
                messages.append(Message(role: "system", content: system))
            }
            messages += request.messages.map(Message.init)
            self.messages = messages
            tools = request.tools.isEmpty ? nil : request.tools.map(Tool.init)
            let options = Options(
                temperature: request.options.temperature,
                numCtx: request.options.contextLength,
                numPredict: request.options.maxTokens
            )
            self.options = options.isEmpty ? nil : options
            keepAlive = request.options.keepAlive
            think = request.options.think
            format = request.responseFormat
        }
    }

    struct Message: Codable {
        var role: String
        var content: String
        var thinking: String?
        var toolCalls: [WireToolCall]?
        var toolName: String?

        enum CodingKeys: String, CodingKey {
            case role, content, thinking
            case toolCalls = "tool_calls"
            case toolName = "tool_name"
        }

        init(role: String, content: String) {
            self.role = role
            self.content = content
        }

        init(_ message: ChatMessage) {
            role = message.role.rawValue
            content = message.content
            if !message.toolCalls.isEmpty {
                toolCalls = message.toolCalls.map {
                    WireToolCall(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments))
                }
            }
            toolName = message.toolName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decodeIfPresent(String.self, forKey: .role) ?? "assistant"
            content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
            thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
            toolCalls = try container.decodeIfPresent([WireToolCall].self, forKey: .toolCalls)
            toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        }
    }

    struct WireToolCall: Codable {
        var id: String?
        var function: Function

        struct Function: Codable {
            var name: String
            var arguments: JSONValue
        }
    }

    struct Tool: Encodable {
        var type = "function"
        var function: Function

        struct Function: Encodable {
            var name: String
            var description: String
            var parameters: JSONValue
        }

        init(_ spec: ToolSpec) {
            function = Function(name: spec.name, description: spec.description, parameters: spec.parameters)
        }
    }

    struct Options: Encodable {
        var temperature: Double?
        var numCtx: Int?
        var numPredict: Int?

        var isEmpty: Bool { temperature == nil && numCtx == nil && numPredict == nil }

        enum CodingKeys: String, CodingKey {
            case temperature
            case numCtx = "num_ctx"
            case numPredict = "num_predict"
        }
    }

    struct ChatChunk: Decodable {
        var message: Message?
        var done: Bool?
        var promptEvalCount: Int?
        var evalCount: Int?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case message, done, error
            case promptEvalCount = "prompt_eval_count"
            case evalCount = "eval_count"
        }
    }

    struct TagsResponse: Decodable {
        var models: [Model]

        struct Model: Decodable {
            var name: String
            var size: Int64?
            var details: Details?
        }

        struct Details: Decodable {
            var parameterSize: String?
            var quantizationLevel: String?

            enum CodingKeys: String, CodingKey {
                case parameterSize = "parameter_size"
                case quantizationLevel = "quantization_level"
            }
        }
    }

    struct EmbedBody: Encodable {
        var model: String
        var input: [String]
    }

    struct EmbedResponse: Decodable {
        var embeddings: [[Float]]
    }
}
