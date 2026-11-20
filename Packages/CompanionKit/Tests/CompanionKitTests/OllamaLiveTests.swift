import CompanionCore
import Foundation
import Testing

@testable import Providers
import Routing
import Tools

/// Hits a real local Ollama. Run with `OLLAMA_LIVE=1 swift test --filter OllamaLiveTests`.
/// Override the model with `OLLAMA_LIVE_MODEL` (default `qwen3:8b`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OLLAMA_LIVE"] == "1"))
struct OllamaLiveTests {
    let provider = OllamaProvider()
    let model = ProcessInfo.processInfo.environment["OLLAMA_LIVE_MODEL"] ?? "qwen3:8b"

    @Test func listsInstalledModels() async throws {
        let models = try await provider.listModels()
        #expect(models.contains { $0.id == model })
    }

    @Test func streamsAReply() async throws {
        let request = ChatRequest(
            model: model,
            messages: [.user("Reply with exactly the word: pong")],
            options: ChatOptions(temperature: 0, think: false)
        )
        let events = try await provider.stream(request).collect()
        let text = events.compactMap { if case .textDelta(let delta) = $0 { delta } else { nil } }.joined()

        #expect(text.lowercased().contains("pong"))
        #expect(events.last.map { if case .done = $0 { true } else { false } } == true)
    }

    @Test func translatesWithTaskProfile() async throws {
        let request = TaskProfiles.defaults[.translate].makeRequest(
            history: [.user("Wie spät ist es?"), .assistant("What time is it?"), .user("Guten Morgen")],
            model: model,
            targetLanguage: "French"
        )
        let events = try await provider.stream(request).collect()
        let text = events.compactMap { if case .textDelta(let delta) = $0 { delta } else { nil } }.joined()

        #expect(text.lowercased().contains("bonjour"))
    }

    @Test(arguments: [
        ("Which e-bike under 3000 euros has the best range? Compare current models.", TaskKind.research),
        ("Why does my SwiftUI list not refresh when the array changes?", .code),
        ("Wie geht es dir heute?", .chat),
        ("Can you put 'Guten Morgen, wie geht es dir?' into Spanish for me", .translate),
    ])
    func classifiesWithLocalModel(text: String, expected: TaskKind) async throws {
        let classifier = LLMTaskClassifier(provider: provider, model: model)
        #expect(try await classifier.classify(text) == expected)
    }

    /// Full research turn: real model, real Wikipedia search, real page fetches.
    @Test func researchesWithWebTools() async throws {
        let researchModel = ProcessInfo.processInfo.environment["OLLAMA_LIVE_RESEARCH_MODEL"] ?? "qwen3:30b-a3b"
        let request = TaskProfiles.defaults[.research].makeRequest(
            history: [.user("In which year was the Swift programming language first released, and who started it?")],
            model: researchModel
        )
        // SEARXNG_URL switches from the keyless Wikipedia backend to a SearXNG instance.
        let backend: any SearchBackend = ProcessInfo.processInfo.environment["SEARXNG_URL"]
            .flatMap(URL.init(string:)).map { SearXNGBackend(baseURL: $0) } ?? WikipediaSearchBackend()
        let loop = ToolLoop(provider: provider, tools: [WebSearchTool(backend: backend), FetchPageTool()])

        var answer = ""
        var toolsUsed: [String] = []
        var failures: [String] = []
        for try await event in loop.run(request) {
            switch event {
            case .text(let delta): answer += delta
            case .toolStarted(let call): toolsUsed.append("\(call.name)(\(call.arguments.jsonString))")
            case .toolFinished(_, _, let error?): failures.append(error)
            default: break
            }
        }
        print("TOOLS:", toolsUsed, "FAILURES:", failures, "\nANSWER:", answer)
        #expect(toolsUsed.contains { $0.hasPrefix("web_search") })
        #expect(answer.contains("2014"))
        #expect(answer.contains("Lattner"))
    }
}
