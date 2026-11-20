import CompanionCore
import Foundation
import Testing

@testable import Routing

@Suite struct TaskProfileTests {
    let history: [ChatMessage] = [.user("Hallo"), .assistant("Hello"), .user("Wie geht's?")]

    @Test func defaultsCoverEveryTask() {
        #expect(TaskProfiles.defaults.all.map(\.task) == TaskKind.allCases)
        #expect(TaskProfiles.defaults[.code].modelID == "qwen3-coder:30b")
    }

    @Test func translateSendsOnlyLastUserMessageWithLanguage() {
        let request = TaskProfiles.defaults[.translate].makeRequest(history: history, targetLanguage: "French")

        #expect(request.messages == [.user("Wie geht's?")])
        #expect(request.system?.contains("into French.") == true)
        #expect(request.system?.contains(TaskProfile.targetLanguagePlaceholder) == false)
        #expect(request.options.think == false)
    }

    @Test func chatKeepsHistoryAndAppliesOptions() {
        var profile = TaskProfiles.defaults[.chat]
        profile.temperature = 0.9
        profile.contextLength = 8192

        let request = profile.makeRequest(history: history)

        #expect(request.model == "gemma4:26b")
        #expect(request.messages == history)
        #expect(request.options == ChatOptions(temperature: 0.9, contextLength: 8192, keepAlive: "10m"))
    }

    @Test func modelOverrideWins() {
        let request = TaskProfiles.defaults[.code].makeRequest(history: history, model: "qwen2.5:32b")
        #expect(request.model == "qwen2.5:32b")
    }

    @Test func emptySystemPromptIsOmitted() {
        var profile = TaskProfiles.defaults[.chat]
        profile.systemPrompt = "  \n"
        #expect(profile.makeRequest(history: history).system == nil)
    }

    @Test func roundTripsAndFillsMissingTasks() throws {
        var profiles = TaskProfiles.defaults
        profiles[.code].modelID = "custom-coder"
        let data = try JSONEncoder().encode(profiles)
        #expect(try JSONDecoder().decode(TaskProfiles.self, from: data) == profiles)

        // A stored list that lacks some tasks still yields a complete set.
        let partial = try JSONEncoder().encode([profiles[.code]])
        let decoded = try JSONDecoder().decode(TaskProfiles.self, from: partial)
        #expect(decoded[.code].modelID == "custom-coder")
        #expect(decoded[.chat] == TaskProfiles.defaults[.chat])
    }

    @Test func subscriptSetterKeepsTaskKey() {
        var profiles = TaskProfiles.defaults
        var wrong = profiles[.chat]
        wrong.task = .code
        profiles[.chat] = wrong
        #expect(profiles[.chat].task == .chat)
    }
}
