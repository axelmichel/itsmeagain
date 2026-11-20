import CompanionCore
import Foundation
import Testing

@testable import AppleIntelligence
@testable import Routing

struct FixedClassifier: TaskClassifier {
    var result: TaskKind?
    var delay: Duration = .zero

    func classify(_ text: String) async throws -> TaskKind {
        try await Task.sleep(for: delay)
        guard let result else { throw ProviderError.server("no") }
        return result
    }
}

/// Replays a canned reply, recording the request.
struct ScriptedProvider: LLMProvider {
    var id = ProviderID("scripted")
    var displayName = "Scripted"
    var capabilities: ProviderCapabilities { [.streaming] }
    var reply: String

    func listModels() async throws -> [ModelInfo] { [] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.yield(.done(nil))
            continuation.finish()
        }
    }
}

@Suite struct TaskRouterTests {
    @Test(arguments: [
        ("Translate this into French: good morning", TaskKind.translate),
        ("Übersetze ins Englische: Guten Morgen", .translate),
        ("bitte übersetze das", .translate),
        ("Research the best e-bikes under 3000€", .research),
        ("Why does this fail?\n```swift\nlet x: Int = \"a\"\n```", .code),
        ("Fatal error at Sources/App/main.swift:42", .code),
        ("import Foundation\nlet url = URL(string: x)\nfunc go() {}", .code),
    ])
    func heuristicsCatchObviousCases(text: String, expected: TaskKind) {
        #expect(TaskRouter.heuristic(text) == expected)
    }

    @Test(arguments: [
        "How do I translate strings in a SwiftUI app?",
        "What's a good recipe for dinner?",
        "Let me know what you think",
        "Erkläre mir Quantencomputer",
    ])
    func ambiguousTextIsLeftToClassifier(text: String) {
        #expect(TaskRouter.heuristic(text) == nil)
    }

    @Test(arguments: [
        ("Translate into French: hello", "French"),
        ("Übersetze ins Französische", "French"),
        ("Übersetze das auf Englisch", "English"),
        ("translate to japanese please", "Japanese"),
        ("Traduis en allemand", "German"),
    ])
    func findsTargetLanguage(text: String, expected: String) {
        #expect(TaskRouter.targetLanguage(in: text) == expected)
    }

    @Test func noTargetLanguage() {
        #expect(TaskRouter.targetLanguage(in: "Translate this text") == nil)
    }

    @Test func usesHeuristicBeforeClassifier() async {
        let router = TaskRouter(classifier: FixedClassifier(result: .chat))
        let decision = await router.route("Übersetze ins Französische: Hallo")
        #expect(decision == RoutingDecision(task: .translate, targetLanguage: "French", source: .heuristic))
    }

    @Test func usesClassifierForAmbiguousText() async {
        let router = TaskRouter(classifier: FixedClassifier(result: .research))
        #expect(await router.route("Which e-bike should I buy?").task == .research)
    }

    @Test func fallsBackToChatOnFailureOrTimeout() async {
        let failing = TaskRouter(classifier: FixedClassifier(result: nil))
        #expect(await failing.route("hello") == RoutingDecision(task: .chat, targetLanguage: nil, source: .fallback))

        let slow = TaskRouter(classifier: FixedClassifier(result: .code, delay: .seconds(5)), timeout: .milliseconds(50))
        let started = ContinuousClock.now
        #expect(await slow.route("hello").source == .fallback)
        #expect(ContinuousClock.now - started < .seconds(2))

        #expect(await TaskRouter(classifier: nil).route("hello").task == .chat)
    }

    @Test func llmClassifierParsesJSONAndLooseText() async throws {
        #expect(try await LLMTaskClassifier(provider: ScriptedProvider(reply: #"{"task":"code"}"#), model: "m").classify("x") == .code)
        #expect(try await LLMTaskClassifier(provider: ScriptedProvider(reply: "Translate."), model: "m").classify("x") == .translate)
        await #expect(throws: ProviderError.self) {
            try await LLMTaskClassifier(provider: ScriptedProvider(reply: "dunno"), model: "m").classify("x")
        }
    }

    @Test func appleOnDevicePromptCondensesHistoryWithinBudget() {
        #expect(AppleOnDeviceProvider.prompt(for: [.user("Hi")]) == "Hi")

        let history: [ChatMessage] = [.user("old " + String(repeating: "x", count: 100)), .assistant("A1"), .user("Q2"), .assistant("A2"), .user("Q3")]
        let prompt = AppleOnDeviceProvider.prompt(for: history, budget: 30)
        #expect(prompt == "Conversation so far:\nUser: Q2\nAssistant: A2\n\nUser: Q3")
    }
}
