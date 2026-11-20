import CompanionCore
import Foundation

/// Any server speaking the OpenAI Chat Completions API: OpenAI, OpenRouter, Groq, Mistral, LM Studio, …
public struct OpenAICompatibleProvider: LLMProvider {
    public let id: ProviderID
    public let displayName: String
    /// Base URL including the version path, e.g. `https://api.openai.com/v1`.
    public let baseURL: URL
    public var capabilities: ProviderCapabilities { [.streaming, .tools] }

    private let apiKey: String?
    private let session: URLSession

    public init(id: ProviderID, displayName: String, baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        let (data, response) = try await load(request(url: baseURL.appending(path: "models")))
        try HTTP.validate(response, body: data)
        let page = try JSONDecoder().decode(ModelsPage.self, from: data)
        return page.data
            .map { ModelInfo(id: $0.id) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: Chat

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = self.request(url: baseURL.appending(path: "chat/completions"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.httpBody = try JSONEncoder().encode(Self.body(request))

                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await session.bytes(for: urlRequest)
                    } catch {
                        throw HTTP.mapConnectionError(error, service: displayName, url: baseURL)
                    }
                    try await HTTP.validate(response, bytes: bytes)

                    var parser = StreamParser()
                    for try await data in SSE.data(bytes.lines) {
                        if data == "[DONE]" { break }
                        for event in try parser.consume(data) { continuation.yield(event) }
                    }
                    for event in parser.finish() { continuation.yield(event) }
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
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw HTTP.mapConnectionError(error, service: displayName, url: baseURL)
        }
    }
}

// MARK: - Streaming

extension OpenAICompatibleProvider {
    struct StreamParser {
        /// Tool calls arrive in fragments keyed by `index`; they're emitted once the stream ends.
        private var tools: [Int: (id: String, name: String, arguments: String)] = [:]
        private var usage: Usage?

        mutating func consume(_ data: String) throws -> [ChatEvent] {
            let chunk = try JSONDecoder().decode(JSONValue.self, from: Data(data.utf8))
            if let error = chunk["error"] {
                throw ProviderError.server(error["message"]?.stringValue ?? error.stringValue ?? "stream error")
            }
            if let usage = chunk["usage"], usage != .null {
                self.usage = Usage(
                    promptTokens: usage["prompt_tokens"]?.intValue,
                    completionTokens: usage["completion_tokens"]?.intValue
                )
            }
            guard case .array(let choices)? = chunk["choices"], let delta = choices.first?["delta"] else { return [] }

            var events: [ChatEvent] = []
            // Reasoning field name differs between servers.
            for key in ["reasoning_content", "reasoning"] {
                if let thinking = delta[key]?.stringValue, !thinking.isEmpty { events.append(.thinkingDelta(thinking)) }
            }
            if let text = delta["content"]?.stringValue, !text.isEmpty {
                events.append(.textDelta(text))
            }
            if case .array(let calls)? = delta["tool_calls"] {
                for call in calls {
                    let index = call["index"]?.intValue ?? 0
                    var tool = tools[index] ?? ("", "", "")
                    if let id = call["id"]?.stringValue { tool.id = id }
                    if let name = call["function"]?["name"]?.stringValue { tool.name += name }
                    tool.arguments += call["function"]?["arguments"]?.stringValue ?? ""
                    tools[index] = tool
                }
            }
            return events
        }

        mutating func finish() -> [ChatEvent] {
            var events: [ChatEvent] = tools.keys.sorted().compactMap { index in
                let tool = tools[index]!
                let json = tool.arguments.isEmpty ? "{}" : tool.arguments
                let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .string(tool.arguments)
                return .toolCall(ToolCall(id: tool.id.isEmpty ? UUID().uuidString : tool.id, name: tool.name, arguments: arguments))
            }
            tools = [:]
            events.append(.done(usage))
            return events
        }
    }
}

// MARK: - Wire format

extension OpenAICompatibleProvider {
    static func body(_ request: ChatRequest) -> JSONValue {
        var messages: [JSONValue] = []
        if let system = request.system, !system.isEmpty {
            messages.append(["role": "system", "content": .string(system)])
        }
        for message in request.messages {
            switch message.role {
            case .tool:
                messages.append([
                    "role": "tool",
                    "tool_call_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.content),
                ])
            case .assistant where !message.toolCalls.isEmpty:
                messages.append([
                    "role": "assistant",
                    "content": message.content.isEmpty ? .null : .string(message.content),
                    "tool_calls": .array(message.toolCalls.map {
                        [
                            "id": .string($0.id),
                            "type": "function",
                            "function": ["name": .string($0.name), "arguments": .string($0.arguments.jsonString)],
                        ]
                    }),
                ])
            default:
                messages.append(["role": .string(message.role.rawValue), "content": .string(message.content)])
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                [
                    "type": "function",
                    "function": ["name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters],
                ]
            })
        }
        if let temperature = request.options.temperature { body["temperature"] = .number(temperature) }
        if let maxTokens = request.options.maxTokens { body["max_tokens"] = .number(Double(maxTokens)) }
        if let schema = request.responseFormat {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "response", "schema": schema]]
        }
        return .object(body)
    }

    struct ModelsPage: Decodable {
        var data: [Model]
        struct Model: Decodable { var id: String }
    }
}
