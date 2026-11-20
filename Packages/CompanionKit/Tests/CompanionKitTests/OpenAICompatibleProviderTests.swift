import CompanionCore
import Foundation
import Synchronization
import Testing

@testable import Providers

@Suite struct OpenAICompatibleProviderTests {
    static func sse(_ chunks: [String]) -> Data {
        Data((chunks.map { "data: \($0)\n\n" } + ["data: [DONE]\n\n"]).joined().utf8)
    }

    @Test func streamsTextReasoningFragmentedToolCallsAndUsage() async throws {
        let body = Self.sse([
            #"{"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"hmm"}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"Hi"}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\"qu"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ery\":\"x\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7}}"#,
        ])
        let (session, url) = StubURLProtocol.make { request, _ in
            #expect(request.url?.path() == "/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
            return .init(body: body, contentType: "text/event-stream")
        }
        let provider = OpenAICompatibleProvider(
            id: ProviderID("openai"), displayName: "OpenAI", baseURL: url.appending(path: "v1"), apiKey: "sk-test", session: session
        )

        let events = try await provider.stream(ChatRequest(model: "gpt", messages: [.user("hi")])).collect()

        #expect(events == [
            .thinkingDelta("hmm"),
            .textDelta("Hi"),
            .toolCall(ToolCall(id: "call_1", name: "web_search", arguments: ["query": "x"])),
            .done(Usage(promptTokens: 5, completionTokens: 7)),
        ])
    }

    @Test func encodesMessagesToolsAndOmitsAuthWithoutKey() async throws {
        let captured = Mutex<(URLRequest, JSONValue)?>(nil)
        let (session, url) = StubURLProtocol.make { request, body in
            captured.withLock { $0 = (request, try! JSONDecoder().decode(JSONValue.self, from: body)) }
            return .init(body: Self.sse([]))
        }
        let provider = OpenAICompatibleProvider(
            id: ProviderID("lmstudio"), displayName: "LM Studio", baseURL: url, apiKey: nil, session: session
        )
        let request = ChatRequest(
            model: "local",
            system: "sys",
            messages: [
                .user("q"),
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c", name: "t", arguments: ["a": 1])]),
                ChatMessage(role: .tool, content: "r", toolCallID: "c", toolName: "t"),
            ],
            tools: [ToolSpec(name: "t", description: "d", parameters: ["type": "object"])],
            options: ChatOptions(temperature: 0.5)
        )

        _ = try await provider.stream(request).collect()

        let (urlRequest, body) = try #require(captured.withLock { $0 })
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(body["temperature"] == 0.5)
        #expect(body["stream_options"] == ["include_usage": true])
        #expect(body["messages"] == [
            ["role": "system", "content": "sys"],
            ["role": "user", "content": "q"],
            ["role": "assistant", "content": nil, "tool_calls": [["id": "c", "type": "function", "function": ["name": "t", "arguments": #"{"a":1}"#]]]],
            ["role": "tool", "tool_call_id": "c", "content": "r"],
        ])
        #expect(body["tools"] == [["type": "function", "function": ["name": "t", "description": "d", "parameters": ["type": "object"]]]])
    }

    @Test func listsModels() async throws {
        let (session, url) = StubURLProtocol.make { _, _ in
            .init(body: Data(#"{"object":"list","data":[{"id":"gpt-b"},{"id":"gpt-a"}]}"#.utf8))
        }
        let provider = OpenAICompatibleProvider(id: ProviderID("x"), displayName: "X", baseURL: url, apiKey: "k", session: session)
        #expect(try await provider.listModels().map(\.id) == ["gpt-a", "gpt-b"])
    }

    @Test func errorChunk() async throws {
        let (session, url) = StubURLProtocol.make { _, _ in
            .init(body: Data(#"data: {"error":{"message":"Rate limit"}}"#.utf8))
        }
        let provider = OpenAICompatibleProvider(id: ProviderID("x"), displayName: "X", baseURL: url, apiKey: "k", session: session)
        await #expect(throws: ProviderError.server("Rate limit")) {
            _ = try await provider.stream(ChatRequest(model: "m", messages: [.user("x")])).collect()
        }
    }
}
