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
        let conversation = Conversation(providerID: "ollama", modelID: "m")
        container.mainContext.insert(conversation)

        conversation.append(role: .user, content: "one")
        conversation.append(role: .assistant, content: "two")
        conversation.append(role: .user, content: "three")
        conversation.append(role: .assistant, content: "")
        try container.mainContext.save()

        #expect(conversation.orderedMessages.map(\.order) == [0, 1, 2, 3])
        #expect(conversation.chatMessages == [.user("one"), .assistant("two"), .user("three")])
    }
}
