import CompanionCore
import Foundation
import Synchronization
import Testing

@testable import Providers

@Suite struct OllamaProviderTests {
    @Test func streamsThinkingTextToolCallsAndUsage() async throws {
        let lines = [
            #"{"message":{"role":"assistant","content":"","thinking":"Hmm"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"Hel"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"lo"},"done":false}"#,
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"web_search","arguments":{"query":"swift"}}}]},"done":false}"#,
            #"{"message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":12,"eval_count":34}"#,
        ]
        let (session, url) = StubURLProtocol.make { _, _ in
            .init(body: Data(lines.joined(separator: "\n").utf8), contentType: "application/x-ndjson")
        }
        let provider = OllamaProvider(baseURL: url, session: session)

        let events = try await provider.stream(ChatRequest(model: "m", messages: [.user("hi")])).collect()

        #expect(events.count == 5)
        #expect(events[0] == .thinkingDelta("Hmm"))
        #expect(events[1] == .textDelta("Hel"))
        #expect(events[2] == .textDelta("lo"))
        guard case .toolCall(let call) = events[3] else {
            Issue.record("expected tool call, got \(events[3])")
            return
        }
        #expect(call.name == "web_search")
        #expect(call.arguments["query"] == "swift")
        #expect(events[4] == .done(Usage(promptTokens: 12, completionTokens: 34)))
    }

    @Test func encodesRequestBody() async throws {
        let captured = Mutex<JSONValue?>(nil)
        let (session, url) = StubURLProtocol.make { request, body in
            #expect(request.url?.path() == "/api/chat")
            captured.withLock { $0 = try? JSONDecoder().decode(JSONValue.self, from: body) }
            return .init(body: Data(#"{"done":true}"#.utf8))
        }
        let provider = OllamaProvider(baseURL: url, session: session)
        let request = ChatRequest(
            model: "qwen3:8b",
            system: "Be brief.",
            messages: [
                .user("hi"),
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "1", name: "t", arguments: ["a": 1])]),
                ChatMessage(role: .tool, content: "result", toolCallID: "1", toolName: "t"),
            ],
            tools: [ToolSpec(name: "t", description: "A tool", parameters: ["type": "object", "maxLength": 3])],
            options: ChatOptions(temperature: 0.2, contextLength: 8192, keepAlive: "5m")
        )

        _ = try await provider.stream(request).collect()

        let body = try #require(captured.withLock { $0 })
        #expect(body["model"] == "qwen3:8b")
        #expect(body["stream"] == true)
        #expect(body["keep_alive"] == "5m")
        #expect(body["think"] == nil, "think must be omitted when unset; non-thinking models reject it")
        #expect(body["options"] == ["temperature": 0.2, "num_ctx": 8192])
        #expect(body["messages"] == [
            ["role": "system", "content": "Be brief."],
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "1", "function": ["name": "t", "arguments": ["a": 1]]]]],
            ["role": "tool", "content": "result", "tool_name": "t"],
        ])
        // Schema keys must pass through untouched (no snake_case conversion).
        #expect(body["tools"] == [["type": "function", "function": ["name": "t", "description": "A tool", "parameters": ["type": "object", "maxLength": 3]]]])
    }

    @Test func surfacesHTTPErrorMessage() async throws {
        let (session, url) = StubURLProtocol.make { _, _ in
            .init(status: 404, body: Data(#"{"error":"model 'nope' not found"}"#.utf8))
        }
        let provider = OllamaProvider(baseURL: url, session: session)

        await #expect(throws: ProviderError.http(status: 404, message: "model 'nope' not found")) {
            _ = try await provider.stream(ChatRequest(model: "nope", messages: [.user("hi")])).collect()
        }
    }

    @Test func surfacesInStreamError() async throws {
        let (session, url) = StubURLProtocol.make { _, _ in
            .init(body: Data(#"{"error":"out of memory"}"#.utf8))
        }
        let provider = OllamaProvider(baseURL: url, session: session)

        await #expect(throws: ProviderError.server("out of memory")) {
            _ = try await provider.stream(ChatRequest(model: "m", messages: [.user("hi")])).collect()
        }
    }

    @Test func listsModelsSorted() async throws {
        let json = #"""
            {"models":[
              {"name":"qwen3:8b","size":5200000000,"details":{"parameter_size":"8.2B","quantization_level":"Q4_K_M"}},
              {"name":"gemma4:26b","size":16000000000}
            ]}
            """#
        let (session, url) = StubURLProtocol.make { _, _ in .init(body: Data(json.utf8)) }
        let provider = OllamaProvider(baseURL: url, session: session)

        let models = try await provider.listModels()

        #expect(models.map(\.id) == ["gemma4:26b", "qwen3:8b"])
        #expect(models[1].details == "8.2B · Q4_K_M")
        #expect(models[0].details == nil)
    }

    @Test func embeds() async throws {
        let (session, url) = StubURLProtocol.make { request, _ in
            #expect(request.url?.path() == "/api/embed")
            return .init(body: Data(#"{"embeddings":[[0.1,0.2],[0.3,0.4]]}"#.utf8))
        }
        let provider = OllamaProvider(baseURL: url, session: session)

        let vectors = try await provider.embed(["a", "b"])

        #expect(vectors == [[0.1, 0.2], [0.3, 0.4]])
    }
}
