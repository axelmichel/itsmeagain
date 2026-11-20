import CompanionCore
import Foundation
import Synchronization
import Testing

@testable import Providers

@Suite struct AnthropicProviderTests {
    static func sse(_ events: [String]) -> Data {
        // Mirrors the real wire format: event line, data line, blank line.
        Data(events.map { event -> String in
            let type = (try? JSONDecoder().decode(JSONValue.self, from: Data(event.utf8)))?["type"]?.stringValue ?? ""
            return "event: \(type)\ndata: \(event)\n\n"
        }.joined().utf8)
    }

    @Test func streamsTextThinkingToolUseAndUsage() async throws {
        let body = Self.sse([
            #"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":21}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me see"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"sw"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"ift\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}"#,
            #"{"type":"message_stop"}"#,
        ])
        let (session, url) = StubURLProtocol.make { _, _ in .init(body: body, contentType: "text/event-stream") }
        let provider = AnthropicProvider(apiKey: "k", baseURL: url, session: session)

        let events = try await provider.stream(ChatRequest(model: "claude-opus-5-5", messages: [.user("hi")])).collect()

        #expect(events == [
            .thinkingDelta("Let me see"),
            .textDelta("Checking."),
            .toolCall(ToolCall(id: "toolu_1", name: "web_search", arguments: ["query": "swift"])),
            .done(Usage(promptTokens: 21, completionTokens: 40)),
        ])
    }

    @Test func encodesRequest() async throws {
        let captured = Mutex<(URLRequest, JSONValue)?>(nil)
        let (session, url) = StubURLProtocol.make { request, body in
            captured.withLock { $0 = (request, try! JSONDecoder().decode(JSONValue.self, from: body)) }
            return .init(body: Self.sse([#"{"type":"message_stop"}"#]))
        }
        let provider = AnthropicProvider(apiKey: "secret", baseURL: url, session: session)
        let request = ChatRequest(
            model: "claude-opus-5-5",
            system: "Be brief.",
            messages: [
                .user("weather?"),
                ChatMessage(role: .assistant, content: "", toolCalls: [
                    ToolCall(id: "a", name: "w", arguments: ["city": "Paris"]),
                    ToolCall(id: "b", name: "w", arguments: ["city": "Rome"]),
                ]),
                ChatMessage(role: .tool, content: "sunny", toolCallID: "a", toolName: "w"),
                ChatMessage(role: .tool, content: "rain", toolCallID: "b", toolName: "w"),
                .assistant(""),
            ],
            tools: [ToolSpec(name: "w", description: "Weather", parameters: ["type": "object"])],
            options: ChatOptions(temperature: 0.3, think: true)
        )

        _ = try await provider.stream(request).collect()

        let (urlRequest, body) = try #require(captured.withLock { $0 })
        #expect(urlRequest.url?.path() == "/v1/messages")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(body["fallbacks"] == "default")
        #expect(body["max_tokens"] == 64_000)
        #expect(body["system"] == "Be brief.")
        #expect(body["temperature"] == nil, "API 2026-10-21 rejects temperature")
        #expect(body["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(body["tools"] == [["name": "w", "description": "Weather", "input_schema": ["type": "object"]]])
        #expect(body["messages"] == [
            ["role": "user", "content": "weather?"],
            ["role": "assistant", "content": [
                ["type": "tool_use", "id": "a", "name": "w", "input": ["city": "Paris"]],
                ["type": "tool_use", "id": "b", "name": "w", "input": ["city": "Rome"]],
            ]],
            // Both results in one user turn; the empty assistant placeholder is dropped.
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "a", "content": "sunny"],
                ["type": "tool_result", "tool_use_id": "b", "content": "rain"],
            ]],
        ])
    }

    @Test func thinkingOffLowersEffortAndOlderModelsGetNoFallback() {
        let body = AnthropicProvider.MessagesBody(
            ChatRequest(model: "claude-haiku-4-5", messages: [.user("hi")], options: ChatOptions(think: false))
        )
        #expect(body.thinking == nil)
        #expect(body.outputConfig == ["effort": "low"])
        #expect(body.fallbacks == nil)
    }

    @Test func refusalBecomesError() async throws {
        let body = Self.sse([
            #"{"type":"message_start","message":{"usage":{"input_tokens":1}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":0}}"#,
            #"{"type":"message_stop"}"#,
        ])
        let (session, url) = StubURLProtocol.make { _, _ in .init(body: body) }
        let provider = AnthropicProvider(apiKey: "k", baseURL: url, session: session)

        await #expect(throws: ProviderError.server("Claude declined this request (cyber).")) {
            _ = try await provider.stream(ChatRequest(model: "m", messages: [.user("x")])).collect()
        }
    }

    @Test func streamErrorEventAndHTTPError() async throws {
        let (s1, u1) = StubURLProtocol.make { _, _ in
            .init(body: Self.sse([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]))
        }
        await #expect(throws: ProviderError.server("Overloaded")) {
            _ = try await AnthropicProvider(apiKey: "k", baseURL: u1, session: s1)
                .stream(ChatRequest(model: "m", messages: [.user("x")])).collect()
        }

        let (s2, u2) = StubURLProtocol.make { _, _ in
            .init(status: 401, body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }
        await #expect(throws: ProviderError.http(status: 401, message: "invalid x-api-key")) {
            _ = try await AnthropicProvider(apiKey: "k", baseURL: u2, session: s2)
                .stream(ChatRequest(model: "m", messages: [.user("x")])).collect()
        }
    }

    @Test func listsModelsAcrossPages() async throws {
        let (session, url) = StubURLProtocol.make { request, _ in
            let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "after_id" }?.value
            let json = after == nil
                ? #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"}],"has_more":true,"last_id":"claude-opus-5-5"}"#
                : #"{"data":[{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}],"has_more":false,"last_id":"claude-haiku-5-5"}"#
            return .init(body: Data(json.utf8))
        }
        let models = try await AnthropicProvider(apiKey: "k", baseURL: url, session: session).listModels()
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-haiku-5-5"])
        #expect(models[0].displayName == "Claude Opus 5.5")
    }
}
