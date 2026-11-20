import CompanionCore
import Foundation

/// Claude via the Anthropic Messages API (raw HTTP + SSE; there is no official Swift SDK).
public struct AnthropicProvider: LLMProvider {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let defaultModel = "claude-opus-5-5"
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    /// Models that accept `fallbacks: "default"` (re-run a refused request on a fallback model).
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    public let id: ProviderID
    public let displayName: String
    public let baseURL: URL
    public var capabilities: ProviderCapabilities { [.streaming, .tools, .thinking, .vision] }

    private let apiKey: String
    private let session: URLSession

    public init(
        id: ProviderID = .anthropic,
        displayName: String = "Anthropic",
        apiKey: String,
        baseURL: URL = AnthropicProvider.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.id = id
        self.displayName = displayName
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        var models: [ModelInfo] = []
        var afterID: String?
        repeat {
            var components = URLComponents(url: baseURL.appending(path: "v1/models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
                + (afterID.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            let (data, response) = try await load(request(url: components.url!))
            try HTTP.validate(response, body: data)
            let page = try JSONDecoder().decode(ModelsPage.self, from: data)
            models += page.data.map { ModelInfo(id: $0.id, displayName: $0.displayName) }
            afterID = page.hasMore ? page.lastID : nil
        } while afterID != nil
        return models
    }

    // MARK: Chat

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = MessagesBody(request)
                    var urlRequest = self.request(url: baseURL.appending(path: "v1/messages"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.httpBody = try JSONEncoder().encode(body)
                    if body.fallbacks != nil {
                        urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
                    }

                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await session.bytes(for: urlRequest)
                    } catch {
                        throw HTTP.mapConnectionError(error, service: "Anthropic", url: baseURL)
                    }
                    try await HTTP.validate(response, bytes: bytes)

                    var parser = StreamParser()
                    for try await data in SSE.data(bytes.lines) {
                        for event in try parser.consume(data) {
                            continuation.yield(event)
                        }
                        if parser.finished { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw HTTP.mapConnectionError(error, service: "Anthropic", url: baseURL)
        }
    }
}

// MARK: - Streaming

extension AnthropicProvider {
    /// Turns SSE `data:` payloads into `ChatEvent`s, assembling streamed tool inputs.
    struct StreamParser {
        private var toolBlocks: [Int: (id: String, name: String, json: String)] = [:]
        private var usage = Usage()
        private(set) var finished = false

        mutating func consume(_ data: String) throws -> [ChatEvent] {
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(data.utf8))
            let index = event["index"].flatMap(\.intValue) ?? 0

            switch event["type"]?.stringValue {
            case "message_start":
                usage.promptTokens = event["message"]?["usage"]?["input_tokens"]?.intValue
            case "content_block_start":
                let block = event["content_block"]
                if block?["type"]?.stringValue == "tool_use" {
                    toolBlocks[index] = (block?["id"]?.stringValue ?? UUID().uuidString, block?["name"]?.stringValue ?? "", "")
                }
            case "content_block_delta":
                let delta = event["delta"]
                switch delta?["type"]?.stringValue {
                case "text_delta":
                    if let text = delta?["text"]?.stringValue, !text.isEmpty { return [.textDelta(text)] }
                case "thinking_delta":
                    if let thinking = delta?["thinking"]?.stringValue, !thinking.isEmpty { return [.thinkingDelta(thinking)] }
                case "input_json_delta":
                    toolBlocks[index]?.json += delta?["partial_json"]?.stringValue ?? ""
                default:
                    break  // signature_delta and future delta types
                }
            case "content_block_stop":
                if let tool = toolBlocks.removeValue(forKey: index) {
                    let json = tool.json.isEmpty ? "{}" : tool.json
                    guard let arguments = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
                        throw ProviderError.invalidResponse("tool input for \(tool.name) is not valid JSON")
                    }
                    return [.toolCall(ToolCall(id: tool.id, name: tool.name, arguments: arguments))]
                }
            case "message_delta":
                if let output = event["usage"]?["output_tokens"]?.intValue { usage.completionTokens = output }
                if event["delta"]?["stop_reason"]?.stringValue == "refusal" {
                    let category = event["delta"]?["stop_details"]?["category"]?.stringValue
                    throw ProviderError.server("Claude declined this request" + (category.map { " (\($0))" } ?? "") + ".")
                }
            case "message_stop":
                finished = true
                return [.done(usage)]
            case "error":
                throw ProviderError.server(event["error"]?["message"]?.stringValue ?? "Anthropic stream error")
            default:
                break  // ping and future event types
            }
            return []
        }
    }
}

// MARK: - Wire format

extension AnthropicProvider {
    struct MessagesBody: Encodable {
        var model: String
        var maxTokens: Int
        var stream = true
        var system: String?
        var messages: [JSONValue]
        var tools: [JSONValue]?
        var thinking: JSONValue?
        var outputConfig: JSONValue?
        var fallbacks: String?

        enum CodingKeys: String, CodingKey {
            case model, stream, system, messages, tools, thinking, fallbacks
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }

        init(_ request: ChatRequest) {
            model = request.model
            maxTokens = request.options.maxTokens ?? 64_000
            system = request.system
            messages = Self.messages(request.messages)
            if !request.tools.isEmpty {
                tools = request.tools.map {
                    ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters]
                }
            }
            // API 2026-10-21 rejects temperature/top_p/top_k, so `options.temperature` is not sent.
            // Thinking can't be disabled on current models; "off" lowers effort instead.
            switch request.options.think {
            case true?: thinking = ["type": "adaptive", "display": "summarized"]
            case false?: outputConfig = ["effort": "low"]
            case nil: break
            }
            if AnthropicProvider.fallbackModels.contains(request.model) {
                fallbacks = "default"
            }
        }

        /// Tool results become `tool_result` blocks in a user turn; consecutive results share one turn.
        static func messages(_ messages: [ChatMessage]) -> [JSONValue] {
            var result: [JSONValue] = []
            var pendingResults: [JSONValue] = []

            func flushResults() {
                guard !pendingResults.isEmpty else { return }
                result.append(["role": "user", "content": .array(pendingResults)])
                pendingResults = []
            }

            for message in messages {
                switch message.role {
                case .tool:
                    pendingResults.append([
                        "type": "tool_result",
                        "tool_use_id": .string(message.toolCallID ?? ""),
                        "content": .string(message.content),
                    ])
                case .assistant:
                    flushResults()
                    if message.toolCalls.isEmpty {
                        guard !message.content.isEmpty else { continue }
                        result.append(["role": "assistant", "content": .string(message.content)])
                    } else {
                        var blocks: [JSONValue] = []
                        if !message.content.isEmpty { blocks.append(["type": "text", "text": .string(message.content)]) }
                        blocks += message.toolCalls.map {
                            ["type": "tool_use", "id": .string($0.id), "name": .string($0.name), "input": $0.arguments]
                        }
                        result.append(["role": "assistant", "content": .array(blocks)])
                    }
                case .user, .system:
                    flushResults()
                    result.append(["role": "user", "content": .string(message.content)])
                }
            }
            flushResults()
            return result
        }
    }

    struct ModelsPage: Decodable {
        var data: [Model]
        var hasMore: Bool
        var lastID: String?

        struct Model: Decodable {
            var id: String
            var displayName: String?

            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }
}
