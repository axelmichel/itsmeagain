import CompanionCore
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
