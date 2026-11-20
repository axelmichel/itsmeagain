import CompanionCore
import Foundation
import Routing
import SwiftData
import Tools

@Model
public final class Conversation {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var taskRaw: String = TaskKind.chat.rawValue
    /// Auto mode: every message is routed to a task; `task` then holds the last routed one.
    public var autoRoute: Bool = false
    /// Translate target; `nil` uses the app default.
    public var targetLanguage: String?

    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.conversation)
    public var messages: [StoredMessage]

    public init(title: String = "New Conversation", task: TaskKind = .chat, autoRoute: Bool = false) {
        id = UUID()
        self.title = title
        createdAt = .now
        updatedAt = .now
        taskRaw = task.rawValue
        self.autoRoute = autoRoute
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
    /// JSON-encoded `[ToolStep]` (kept as Data to stay a plain attribute in SwiftData).
    public var toolStepsData: Data?
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

    public var toolSteps: [ToolStep] {
        get { toolStepsData.flatMap { try? JSONDecoder().decode([ToolStep].self, from: $0) } ?? [] }
        set { toolStepsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
}

/// One tool call shown in the transcript ("Searched …", "Read …").
public struct ToolStep: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case running, done, failed }

    public var id: String
    public var tool: String
    /// The query or URL, for display.
    public var subject: String
    public var status: Status
    public var error: String?
    public var sources: [SourceRef]

    public init(id: String, tool: String, subject: String, status: Status = .running, error: String? = nil, sources: [SourceRef] = []) {
        self.id = id
        self.tool = tool
        self.subject = subject
        self.status = status
        self.error = error
        self.sources = sources
    }
}

public enum CompanionSchema {
    public static let models: [any PersistentModel.Type] = [Conversation.self, StoredMessage.self]
}
