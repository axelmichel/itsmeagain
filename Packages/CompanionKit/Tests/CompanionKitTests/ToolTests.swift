import CompanionCore
import Foundation
import Synchronization
import Testing

@testable import Routing
@testable import Tools

/// Plays back one scripted response per round and records the requests it received.
final class RoundScriptProvider: LLMProvider, @unchecked Sendable {
    let id = ProviderID("script")
    let displayName = "Script"
    var capabilities: ProviderCapabilities { [.streaming, .tools] }
    private let rounds: [[ChatEvent]]
    let requests = Mutex<[ChatRequest]>([])

    init(_ rounds: [[ChatEvent]]) { self.rounds = rounds }

    func listModels() async throws -> [ModelInfo] { [] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let index = requests.withLock { $0.append(request); return $0.count - 1 }
        let events = index < rounds.count ? rounds[index] : [.textDelta("(no more rounds)")]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

struct EchoTool: Tool {
    var name = "echo"
    var delay: Duration = .zero
    var spec: ToolSpec { ToolSpec(name: name, description: "Echo", parameters: ["type": "object"]) }

    func run(_ arguments: JSONValue) async throws -> ToolOutput {
        try await Task.sleep(for: delay)
        let text = try arguments.requiredString("text")
        return ToolOutput(content: "echo: \(text)", sources: [SourceRef(title: text, url: "https://example.com/\(text)")])
    }
}

@Suite struct ToolLoopTests {
    @Test func runsToolsAndFeedsResultsBack() async throws {
        let raw: JSONValue = [["type": "thinking", "thinking": "t", "signature": "s"]]
        let provider = RoundScriptProvider([
            [
                .textDelta("Looking."),
                .toolCall(ToolCall(id: "1", name: "echo", arguments: ["text": "a"])),
                .toolCall(ToolCall(id: "2", name: "echo", arguments: [:])),
                .toolCall(ToolCall(id: "3", name: "nope", arguments: [:])),
                .assistantContent(raw),
                .done(nil),
            ],
            [.textDelta("Answer [1]."), .done(nil)],
        ])
        let loop = ToolLoop(provider: provider, tools: [EchoTool()])

        let events = try await loop.run(ChatRequest(model: "m", messages: [.user("q")])).collect()

        #expect(events.first == .text("Looking."))
        #expect(events.contains(.roundStarted))
        #expect(events.last == .text("Answer [1]."))
        #expect(events.contains(.toolFinished(
            id: "1",
            output: ToolOutput(content: "echo: a", sources: [SourceRef(title: "a", url: "https://example.com/a")]),
            error: nil
        )))
        #expect(events.contains(.toolFinished(id: "2", output: nil, error: "Missing required argument “text”.")))
        #expect(events.contains(.toolFinished(id: "3", output: nil, error: "Unknown tool “nope”.")))

        let requests = provider.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests[0].tools.map(\.name) == ["echo"])
        let followUp = requests[1].messages
        #expect(followUp[1].role == .assistant)
        #expect(followUp[1].toolCalls.map(\.id) == ["1", "2", "3"])
        #expect(followUp[1].providerContent == raw, "raw blocks must be replayed in the next round")
        #expect(followUp[2...].map(\.toolCallID) == ["1", "2", "3"])
        #expect(followUp[2].content == "echo: a")
        #expect(followUp[3].content.hasPrefix("Error:"))
    }

    @Test func stopsAfterMaxRounds() async throws {
        let call: [ChatEvent] = [.toolCall(ToolCall(id: "x", name: "echo", arguments: ["text": "a"])), .done(nil)]
        let loop = ToolLoop(provider: RoundScriptProvider([call, call, call]), tools: [EchoTool()], maxRounds: 2)
        let events = try await loop.run(ChatRequest(model: "m", messages: [.user("q")])).collect()
        #expect(events.last == .text("\n\n_Stopped after 2 rounds of tool use._"))
    }

    @Test func toolTimeoutIsReportedNotThrown() async throws {
        let provider = RoundScriptProvider([
            [.toolCall(ToolCall(id: "1", name: "echo", arguments: ["text": "a"])), .done(nil)],
            [.textDelta("ok"), .done(nil)],
        ])
        let loop = ToolLoop(provider: provider, tools: [EchoTool(delay: .seconds(10))], toolTimeout: .milliseconds(50))
        let events = try await loop.run(ChatRequest(model: "m", messages: [.user("q")])).collect()
        #expect(events.contains(.toolFinished(id: "1", output: nil, error: "echo timed out.")))
    }

    @Test func providersWithoutToolSupportGetAPlainRequest() async throws {
        struct Plain: LLMProvider {
            let id = ProviderID("plain")
            let displayName = "Plain"
            var capabilities: ProviderCapabilities { [.streaming] }
            func listModels() async throws -> [ModelInfo] { [] }
            func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
                AsyncThrowingStream { $0.yield(.textDelta("tools: \(request.tools.count)")); $0.finish() }
            }
        }
        let events = try await ToolLoop(provider: Plain(), tools: [EchoTool()]).run(ChatRequest(model: "m", messages: [])).collect()
        #expect(events == [.text("tools: 0")])
    }
}

@Suite struct FetchPageTests {
    @Test(arguments: [
        "http://localhost:11434/api/tags", "http://127.0.0.1/", "http://10.0.0.5/admin", "http://192.168.1.1",
        "http://172.20.1.1", "http://169.254.169.254/latest/meta-data", "http://[::1]:8080/", "http://router/",
        "http://printer.local/", "file:///etc/passwd", "ftp://example.com/x", "http://[fd00::1]/", "http://100.64.0.1/",
    ])
    func refusesLocalAndNonHTTPURLs(url: String) {
        #expect(throws: ToolError.self) { try FetchPageTool.validatedURL(url) }
    }

    @Test(arguments: ["https://www.example.com/a?b=c", "http://93.184.216.34/", "https://[2606:4700::1111]/"])
    func allowsPublicURLs(url: String) throws {
        #expect(try FetchPageTool.validatedURL(url).absoluteString == url)
    }

    @Test func extractsMainContent() throws {
        let html = """
            <html><head><title>Swift Concurrency</title><script>var x = 1;</script></head><body>
            <nav><a href="/">Home</a> <a href="/docs">Docs</a></nav>
            <article>
              <h1>Structured concurrency</h1>
              <p>Tasks form a <b>tree</b>.</p>
              <ul><li><p>Child tasks</p></li><li>Task groups</li></ul>
              <pre>let x = await f()
            print(x)</pre>
            </article>
            <footer>© 2026</footer>
            </body></html>
            """
        let page = try HTMLText.extract(html, baseURL: URL(string: "https://example.com")!)
        #expect(page.title == "Swift Concurrency")
        #expect(page.text == """
            # Structured concurrency

            Tasks form a tree.

            - Child tasks

            - Task groups

            ```
            let x = await f()
            print(x)
            ```
            """)
    }

    @Test func fetchesAndTruncates() async throws {
        let body = "<html><head><title>T</title></head><body><main><p>\(String(repeating: "word ", count: 100))</p></main></body></html>"
        let (session, url) = StubURLProtocol.make { _, _ in .init(body: Data(body.utf8), contentType: "text/html; charset=utf-8") }
        let page = url.appending(path: "page").absoluteString
        let tool = FetchPageTool(maxCharacters: 50, session: session)
        let output = try await tool.run(["url": .string(page)])
        #expect(output.content.hasPrefix("Title: T\nURL: \(page)\n\nword word"))
        #expect(output.content.hasSuffix("[… truncated]"))
        #expect(output.sources == [SourceRef(title: "T", url: page)])
    }
}

@Suite struct SearchBackendTests {
    @Test func wikipedia() async throws {
        let json = #"{"query":{"search":[{"title":"Swift (programming language)","snippet":"<span class=\"searchmatch\">Swift</span> 5.5 added async"}]}}"#
        let (session, url) = StubURLProtocol.make { request, _ in
            #expect(request.url?.query()?.contains("srsearch=swift") == true)
            return .init(body: Data(json.utf8))
        }
        let results = try await WikipediaSearchBackend(language: "en", host: url.host()!, session: session).search("swift", count: 3)
        #expect(results == [SearchResult(
            title: "Swift (programming language)",
            url: "https://en.wikipedia.org/wiki/Swift_(programming_language)",
            snippet: "Swift 5.5 added async"
        )])
    }

    @Test func searxng() async throws {
        let json = #"{"results":[{"title":"A","url":"https://a.example","content":"about a"},{"title":"B","url":"https://b.example","content":"b"}]}"#
        let (session, url) = StubURLProtocol.make { request, _ in
            #expect(request.url?.path() == "/search")
            #expect(request.url?.query()?.contains("format=json") == true)
            return .init(body: Data(json.utf8))
        }
        let results = try await SearXNGBackend(baseURL: url, session: session).search("q", count: 1)
        #expect(results == [SearchResult(title: "A", url: "https://a.example", snippet: "about a")])
    }

    @Test func brave() async throws {
        let json = #"{"web":{"results":[{"title":"<strong>Swift</strong>","url":"https://swift.org","description":"The <strong>Swift</strong> language"}]}}"#
        let (session, url) = StubURLProtocol.make { request, _ in
            #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == "key")
            return .init(body: Data(json.utf8))
        }
        let results = try await BraveSearchBackend(apiKey: "key", endpoint: url, session: session).search("swift", count: 5)
        #expect(results == [SearchResult(title: "Swift", url: "https://swift.org", snippet: "The Swift language")])
    }

    @Test func ollamaWebSearch() async throws {
        let json = #"{"results":[{"title":"T","url":"https://t.example","content":"body"}]}"#
        let (session, url) = StubURLProtocol.make { request, body in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer key")
            #expect((try? JSONDecoder().decode(JSONValue.self, from: body))?["query"] == "q")
            return .init(body: Data(json.utf8))
        }
        let results = try await OllamaWebSearchBackend(apiKey: "key", endpoint: url, session: session).search("q", count: 5)
        #expect(results == [SearchResult(title: "T", url: "https://t.example", snippet: "body")])
    }

    @Test func toolFormatsResultsAndReportsHTTPErrors() async throws {
        struct Fixed: SearchBackend {
            var name: String { "Fixed" }
            func search(_ query: String, count: Int) async throws -> [SearchResult] {
                [SearchResult(title: "A", url: "https://a.example", snippet: "s")]
            }
        }
        let output = try await WebSearchTool(backend: Fixed()).run(["query": "x"])
        #expect(output.content == "[1] A\nhttps://a.example\ns")

        let (session, url) = StubURLProtocol.make { _, _ in .init(status: 429, body: Data()) }
        await #expect(throws: ToolError.failed("Search failed (HTTP 429).")) {
            try await SearXNGBackend(baseURL: url, session: session).search("q", count: 1)
        }
    }
}

@Suite struct TaskProfileMigrationTests {
    @Test func profilesSavedBeforeToolsExistedGetDefaultTools() throws {
        let old = #"[{"task":"research","providerID":"ollama","modelID":"my-model","systemPrompt":"custom","includesHistory":true}]"#
        let profiles = try JSONDecoder().decode(TaskProfiles.self, from: Data(old.utf8))
        #expect(profiles[.research].modelID == "my-model")
        #expect(profiles[.research].systemPrompt == "custom")
        #expect(profiles[.research].tools == ["web_search", "fetch_page", "search_documents"])
        #expect(profiles[.chat].tools == ["search_documents"])
    }

    @Test func chatIsLocalOnlyAndStoredProfilesCannotDisableIt() throws {
        #expect(TaskProfiles.defaults[.chat].localOnly)
        #expect(!TaskProfiles.defaults[.code].localOnly)
        let stored = #"[{"task":"chat","providerID":"anthropic","modelID":"claude-opus-5-5","systemPrompt":"x","includesHistory":true,"tools":[],"localOnly":false}]"#
        let profiles = try JSONDecoder().decode(TaskProfiles.self, from: Data(stored.utf8))
        #expect(profiles[.chat].localOnly, "localOnly is not user-editable")
        #expect(profiles[.chat].providerID.rawValue == "anthropic", "the (invalid) mapping is kept and rejected at send time")
    }

    @Test func datePlaceholderIsFilled() {
        var profile = TaskProfiles.defaults[.chat]
        profile.systemPrompt = "Today is {{date}}."
        let year = Calendar.current.component(.year, from: .now)
        #expect(profile.makeRequest(history: [.user("hi")]).system?.contains(String(year)) == true)
    }
}

@Suite struct ToolLoopRepeatTests {
    @Test func repeatedCallIsNotRunAgain() async throws {
        let call: [ChatEvent] = [.toolCall(ToolCall(id: UUID().uuidString, name: "echo", arguments: ["text": "a"])), .done(nil)]
        let provider = RoundScriptProvider([call, call, [.textDelta("done"), .done(nil)]])
        let events = try await ToolLoop(provider: provider, tools: [EchoTool()]).run(ChatRequest(model: "m", messages: [])).collect()
        let finished = events.compactMap { if case .toolFinished(_, let output, let error) = $0 { (output != nil, error) } else { nil } }
        #expect(finished.count == 2)
        #expect(finished[0].0 == true)
        #expect(finished[1].1?.hasPrefix("You already made this exact call") == true)
    }
}

@Suite struct SearchFallbackTests {
    struct Fixed: SearchBackend {
        var name: String
        var fails = false
        func search(_ query: String, count: Int) async throws -> [SearchResult] {
            if fails { throw URLError(.cannotConnectToHost) }
            return [SearchResult(title: name, url: "https://\(name.lowercased()).example", snippet: "s")]
        }
    }

    @Test func usesFallbackOnlyWhenPrimaryFails() async throws {
        let healthy = try await WebSearchTool(backend: Fixed(name: "SearXNG"), fallback: Fixed(name: "Wikipedia")).run(["query": "x"])
        #expect(healthy.content.hasPrefix("[1] SearXNG"))

        let offline = try await WebSearchTool(backend: Fixed(name: "SearXNG", fails: true), fallback: Fixed(name: "Wikipedia")).run(["query": "x"])
        #expect(offline.content.hasPrefix("Note: SearXNG is unavailable"))
        #expect(offline.content.contains("[1] Wikipedia"))
        #expect(offline.sources.map(\.title) == ["Wikipedia"])

        await #expect(throws: URLError.self) {
            try await WebSearchTool(backend: Fixed(name: "SearXNG", fails: true)).run(["query": "x"])
        }
    }
}
