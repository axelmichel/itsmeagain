import CompanionCore
import Foundation
import Testing

@testable import Providers
import Routing

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
}
