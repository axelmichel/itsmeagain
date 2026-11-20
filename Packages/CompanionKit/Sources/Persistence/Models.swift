import CompanionCore
import Foundation
import Routing
import SwiftData

@Model
public final class Conversation {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var taskRaw: String = TaskKind.chat.rawValue
    /// Per-conversation override of the task's provider/model; `nil` follows the task mapping.
    public var providerOverride: String?
    public var modelOverride: String?
    /// Translate target; `nil` uses the app default.
    public var targetLanguage: String?

    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
    public var messages: [StoredMessage]

    public init(title: String = "New Conversation", task: TaskKind = .chat) {
        id = UUID()
        self.title = title
        createdAt = .now
        updatedAt = .now
        taskRaw = task.rawValue
        messages = []
    }

    public var task: TaskKind {
        get { TaskKind(rawValue: taskRaw) ?? .chat }
        set { taskRaw = newValue.rawValue }
    }

    public var orderedMessages: [StoredMessage] {
        messages.sorted { $0.order < $1.order }
    }

    /// Appends a message at the end of the transcript.
    @discardableResult
    public func append(role: Role, content: String, modelID: String? = nil, task: TaskKind? = nil) -> StoredMessage {
        let next = (messages.map(\.order).max() ?? -1) + 1
        let message = StoredMessage(role: role, content: content, order: next, modelID: modelID, task: task)
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
    public var taskRaw: String?
    public var errorText: String?
    public var conversation: Conversation?

    public init(role: Role, content: String, order: Int, modelID: String? = nil, task: TaskKind? = nil) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        thinking = ""
        createdAt = .now
        self.order = order
        self.modelID = modelID
        taskRaw = task?.rawValue
    }

    public var role: Role { Role(rawValue: roleRaw) ?? .user }
    public var task: TaskKind? { taskRaw.flatMap(TaskKind.init(rawValue:)) }
}

public enum CompanionSchema {
    public static let models: [any PersistentModel.Type] = [Conversation.self, StoredMessage.self]
}
