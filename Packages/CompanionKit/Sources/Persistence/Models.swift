import CompanionCore
import Foundation
import SwiftData

@Model
public final class Conversation {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Provider + model the conversation last used; the next turn defaults to these.
    public var providerID: String
    public var modelID: String

    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
    public var messages: [StoredMessage]

    public init(title: String = "New Conversation", providerID: String, modelID: String) {
        id = UUID()
        self.title = title
        createdAt = .now
        updatedAt = .now
        self.providerID = providerID
        self.modelID = modelID
        messages = []
    }

    public var orderedMessages: [StoredMessage] {
        messages.sorted { $0.order < $1.order }
    }

    /// Appends a message at the end of the transcript.
    @discardableResult
    public func append(role: Role, content: String, modelID: String? = nil) -> StoredMessage {
        let next = (messages.map(\.order).max() ?? -1) + 1
        let message = StoredMessage(role: role, content: content, order: next, modelID: modelID)
        messages.append(message)
        updatedAt = .now
        return message
    }

    /// The transcript in provider-neutral form, skipping empty assistant placeholders.
    public var chatMessages: [ChatMessage] {
        orderedMessages
            .filter { !($0.role == .assistant && $0.content.isEmpty) }
            .map { ChatMessage(role: $0.role, content: $0.content) }
    }
}

@Model
public final class StoredMessage {
    public var id: UUID
    public var roleRaw: String
    public var content: String
    public var thinking: String
    public var createdAt: Date
    public var order: Int
    public var modelID: String?
    public var errorText: String?
    public var conversation: Conversation?

    public init(role: Role, content: String, order: Int, modelID: String? = nil) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        thinking = ""
        createdAt = .now
        self.order = order
        self.modelID = modelID
    }

    public var role: Role { Role(rawValue: roleRaw) ?? .user }
}

public enum CompanionSchema {
    public static let models: [any PersistentModel.Type] = [Conversation.self, StoredMessage.self]
}
