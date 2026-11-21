import CompanionCore
import Foundation
import NaturalLanguage
import Synchronization
import Testing

@testable import PersonalData
@testable import Providers
@testable import Routing
@testable import Tools
@testable import Mail
@testable import Commands

/// Which local model uses the calendar tools reliably? `OLLAMA_LIVE=1 swift test --filter AssistantLiveTests`
/// (models via `ASSISTANT_MODELS=gemma4:26b,qwen3:30b-a3b`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OLLAMA_LIVE"] == "1"), .serialized)
struct AssistantLiveTests {
    static let models = (ProcessInfo.processInfo.environment["ASSISTANT_MODELS"] ?? "gemma4:26b,qwen3:30b-a3b")
        .split(separator: ",").map(String.init)

    struct Case: Sendable {
        var prompt: String
        var expectedTool: String
        var check: @Sendable (ToolCall?, String) -> Bool
    }

    static let cases: [Case] = [
        Case(prompt: "What do I have on Tuesday, 24 November 2026?", expectedTool: "calendar_events") { call, answer in
            call?.arguments["from"]?.stringValue?.hasPrefix("2026-11-24") == true && answer.contains("Dentist")
        },
        Case(prompt: "Find me a free hour on Wednesday, 25 November 2026.", expectedTool: "free_slots") { call, _ in
            call?.arguments["from"]?.stringValue?.hasPrefix("2026-11-25") == true && call?.arguments["minutes"]?.intValue == 60
        },
        Case(prompt: "Remind me to call mum on Friday, 27 November 2026 at 6pm.", expectedTool: "create_reminder") { call, _ in
            call?.arguments["due"]?.stringValue?.hasPrefix("2026-11-27T18:00") == true
        },
    ]

    @Test(arguments: models)
    func usesCalendarTools(model: String) async throws {
        var passed = 0
        var notes: [String] = []
        for testCase in Self.cases {
            let store = FakeCalendarStore(events: [
                CalendarEvent(id: "e1", title: "Dentist", start: at("2026-11-24T15:00"), end: at("2026-11-24T16:00"), calendar: "Private"),
                CalendarEvent(id: "e2", title: "1:1", start: at("2026-11-25T09:00"), end: at("2026-11-25T09:30"), calendar: "Work"),
            ])
            let request = TaskProfiles.defaults[.chat].makeRequest(history: [.user(testCase.prompt)], model: model)
            let loop = ToolLoop(
                provider: OllamaProvider(),
                tools: CalendarToolbox.tools(store: store, events: true, reminders: true),
                policy: ToolPolicy(providerIsLocal: true) { _ in true }
            )
            let started = ContinuousClock.now
            var calls: [ToolCall] = []
            var answer = ""
            for try await event in loop.run(request) {
                if case .toolStarted(let call) = event { calls.append(call) }
                if case .text(let delta) = event { answer += delta }
            }
            let call = calls.first { $0.name == testCase.expectedTool }
            let ok = testCase.check(call, answer)
            if ok { passed += 1 }
            notes.append("\(ok ? "✓" : "✗") \(testCase.expectedTool) in \(ContinuousClock.now - started): calls=\(calls.map { "\($0.name)\($0.arguments.jsonString)" })")
        }
        print("MODEL \(model): \(passed)/\(Self.cases.count)\n  " + notes.joined(separator: "\n  "))
        #expect(passed >= 2, "\(model) handled only \(passed) of \(Self.cases.count) calendar tasks")
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OLLAMA_LIVE"] == "1"))
struct TriageLiveTests {
    @Test func triagesFakeInbox() async throws {
        let source = FakeMailSource(messages: sampleMail)
        source.rawSources = ["<a1@x>": "Content-Type: text/plain\n\nHi, can you send me the Q1 budget numbers by Monday? Thanks, Tom"]
        let started = ContinuousClock.now
        let items = await TriageClassifier.classify(
            sampleMail.filter { !$0.isRead }, preferences: MailPreferences(vipSenders: ["tom@company.de"]), rules: SenderRuleBook(),
            source: source, model: (OllamaProvider(), "gemma4:26b"))
        for item in TriageClassifier.ordered(items) {
            print("TRIAGE LIVE: [\(item.category.rawValue)] \(item.message.subject)\(item.ask.map { " → \($0)" } ?? "")")
        }
        print("TRIAGE LIVE: \(ContinuousClock.now - started)")
        let budget = try #require(items.first { $0.message.id == "<a1@x>" })
        #expect(budget.category == .needsReply)
        #expect(budget.ask?.localizedCaseInsensitiveContains("Q1") == true || budget.ask?.localizedCaseInsensitiveContains("budget") == true)
        #expect(items.first { $0.message.id == "<a4@x>" }?.category == .automated)
    }

    @Test func draftsAReplyInTheOriginalLanguage() async throws {
        let original = "Hallo Axel, passt dir ein Termin am Donnerstag um 14 Uhr für das Budget? Viele Grüße, Tom"
        let body = try await ReplyDrafter.draft(
            intent: "ja passt, bringe die Zahlen mit", original: original, message: sampleMail[0], userName: "Axel",
            provider: OllamaProvider(), model: "gemma4:26b")
        print("TRIAGE LIVE draft:\n\(body)")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(body)
        #expect(recognizer.dominantLanguage == .german)
        #expect(body.contains("Axel"))
    }
}
