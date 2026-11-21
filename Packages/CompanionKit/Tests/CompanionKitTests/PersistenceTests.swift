import CompanionCore
import PersonalData
import Foundation
import SwiftData
import Testing

@testable import Persistence

@Suite struct PersistenceTests {
    @MainActor
    @Test func transcriptKeepsOrderAndSkipsEmptyAssistantPlaceholder() throws {
        let container = try ModelContainer(
            for: Schema(CompanionSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let conversation = Conversation()
        container.mainContext.insert(conversation)

        conversation.append(role: .user, content: "one")
        conversation.append(role: .assistant, content: "two")
        conversation.append(role: .user, content: "three")
        conversation.append(role: .assistant, content: "")
        try container.mainContext.save()

        #expect(conversation.orderedMessages.map(\.order) == [0, 1, 2, 3])
        #expect(conversation.chatMessages == [.user("one"), .assistant("two"), .user("three")])

        // Commands: the transcript shows what was typed, the model gets the expanded prompt.
        conversation.append(role: .user, content: "/standup API").modelContent = "Draft my stand-up. Focus: API"
        #expect(conversation.orderedMessages.last?.content == "/standup API")
        #expect(conversation.chatMessages.last == .user("Draft my stand-up. Focus: API"))

        // Attachments reach the model as text, so follow-up questions about them work.
        let list = conversation.append(role: .assistant, content: "")
        list.attachments = [.reminders(title: "Open reminders", items: [ReminderItem(id: "r1", title: "Pay rent", list: "Home")])]
        #expect(conversation.chatMessages.last == .assistant("Open reminders:\n- Pay rent [Home] (id r1)"))
    }
}

/// Opens a copy of a real store with the current schema (migration check before shipping schema changes).
/// `ITSMEAGAIN_STORE_COPY=/path/to/copy.store swift test --filter StoreMigrationTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ITSMEAGAIN_STORE_COPY"] != nil))
struct StoreMigrationTests {
    @MainActor
    @Test func opensExistingStore() throws {
        let url = URL(filePath: ProcessInfo.processInfo.environment["ITSMEAGAIN_STORE_COPY"]!)
        let container = try ModelContainer(for: Schema(CompanionSchema.models), configurations: ModelConfiguration(url: url))
        let conversations = try container.mainContext.fetch(FetchDescriptor<Conversation>())
        let messages = try container.mainContext.fetch(FetchDescriptor<StoredMessage>())
        print("MIGRATED: \(conversations.count) conversations, \(messages.count) messages")
        #expect(!conversations.isEmpty)
    }
}

@Suite struct TranscriptEditingTests {
    @MainActor
    @Test func deletingAQuestionTakesItsAnswersAndSearchFindsContent() throws {
        let container = try ModelContainer(for: Schema(CompanionSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let conversation = Conversation(title: "Trip")
        container.mainContext.insert(conversation)
        let q1 = conversation.append(role: .user, content: "Where is Zürich?")
        let a1 = conversation.append(role: .assistant, content: "In Switzerland.")
        let a1b = conversation.append(role: .assistant, content: "Also: it's big.")
        let q2 = conversation.append(role: .user, content: "And Bern?")
        let a2 = conversation.append(role: .assistant, content: "The capital, also Swiss.")

        #expect(conversation.deletion(of: q1, withAnswer: true).map(\.id) == [q1, a1, a1b].map(\.id))
        #expect(conversation.deletion(of: q1, withAnswer: false).map(\.id) == [q1.id])
        #expect(conversation.deletion(of: a1, withAnswer: true).map(\.id) == [a1.id], "answers delete alone")
        #expect(conversation.deletion(of: q2, withAnswer: true).map(\.id) == [q2, a2].map(\.id))

        #expect(conversation.messages(matching: "zurich").map(\.id) == [q1.id], "diacritics ignored")
        #expect(conversation.messages(matching: "SWISS").map(\.id) == [a2.id])
        #expect(conversation.messages(matching: " ").isEmpty)
        #expect(conversation.matches("trip") && conversation.matches("capital") && !conversation.matches("Paris"))
    }
}
