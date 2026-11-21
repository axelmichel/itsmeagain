import Automation
import CompanionCore
import PersonalData
import Foundation
import Mail
import Obsidian
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

    /// What deleting `message` removes: the message itself, and for a question (`withAnswer`) the
    /// replies up to the next question.
    public func deletion(of message: StoredMessage, withAnswer: Bool) -> [StoredMessage] {
        let ordered = orderedMessages
        guard let index = ordered.firstIndex(where: { $0.id == message.id }) else { return [] }
        guard withAnswer, message.role == .user else { return [message] }
        let replies = ordered[(index + 1)...].prefix { $0.role != .user }
        return [message] + replies
    }

    /// Messages containing `query` (case- and diacritic-insensitive), in transcript order.
    public func messages(matching query: String) -> [StoredMessage] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return orderedMessages.filter { $0.content.localizedStandardContains(query) }
    }

    /// Title or any message contains `query`.
    public func matches(_ query: String) -> Bool {
        title.localizedStandardContains(query) || messages.contains { $0.content.localizedStandardContains(query) }
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
            .filter { !($0.role == .assistant && $0.content.isEmpty && $0.attachmentsData == nil) }
            .map { ChatMessage(role: $0.role, content: $0.textForModel) }
    }
}

@Model
public final class StoredMessage {
    public var id: UUID
    public var roleRaw: String
    /// What the transcript shows (e.g. "/standup API").
    public var content: String
    /// What the model receives instead, when it differs (e.g. the expanded command prompt).
    public var modelContent: String?
    public var thinking: String
    public var createdAt: Date
    public var order: Int
    public var modelID: String?
    public var taskRaw: String?
    public var errorText: String?
    /// JSON-encoded `[ToolStep]` (kept as Data to stay a plain attribute in SwiftData).
    public var toolStepsData: Data?
    /// JSON-encoded `[MessageAttachment]`: structured, interactive content (e.g. a reminder list).
    public var attachmentsData: Data?
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

    public var attachments: [MessageAttachment] {
        get { attachmentsData.flatMap { try? JSONDecoder().decode([MessageAttachment].self, from: $0) } ?? [] }
        set { attachmentsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// What the model receives for this message: content plus a text form of the attachments.
    public var textForModel: String {
        let text = modelContent ?? content
        let extra = attachments.map(\.textForModel).filter { !$0.isEmpty }
        return extra.isEmpty ? text : ([text] + extra).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public enum CalendarCardStyle: String, Codable, Sendable, Hashable {
    /// One day's timeline (with the month grid folded away).
    case day
    /// Seven days from `date`.
    case week
    /// Month grid plus the selected day.
    case month
}

/// Structured content shown interactively in the transcript.
public enum MessageAttachment: Codable, Sendable, Hashable {
    /// A reminder list with checkboxes, due-date menus and delete.
    case reminders(title: String, items: [ReminderItem])
    /// Mailing-list senders with Junk / Digest / Keep / Unsubscribe buttons.
    case mailCleanup(groups: [SenderGroup])
    /// A live calendar card (events are read from EventKit when shown); `date` is the selected day.
    case calendar(style: CalendarCardStyle, date: Date)
    /// Memory items with Forget / Edit / Accept (read live from the memory file).
    case memories(title: String, ids: [UUID])
    /// Appointments found in mail, with free/conflict status and Add / Ignore.
    case appointments([AppointmentProposal])
    /// Tasks from Obsidian notes with checkboxes (ticking writes the note).
    case vaultTasks(title: String, tasks: [VaultTask])
    /// Unread mail sorted for /triage, with Read / Archive / Delete / Reply / Rule per mail.
    case mailTriage([TriageItem])

    public var textForModel: String {
        switch self {
        case .reminders(let title, let items):
            guard !items.isEmpty else { return "\(title): none" }
            return "\(title):\n" + items.map { "- " + AgendaFormatter.reminderLine($0) + " (id \($0.id))" }.joined(separator: "\n")
        case .appointments(let items):
            return "Appointments found in mail:\n" + items.map { item in
                "- \(item.title), \(ToolDate.day(item.start)) \(item.isAllDay ? "all day" : ToolDate.time(item.start)) (from \(item.sender); \(item.status.rawValue))"
            }.joined(separator: "\n")
        case .mailTriage(let items):
            return "Triaged unread mail:\n" + items.map { item in
                "- [\(item.category.rawValue)] \(item.message.subject) — \(item.message.senderName)"
                    + (item.ask.map { ": \($0)" } ?? "") + (item.handled.map { " (\($0.rawValue))" } ?? "") + " (id \(item.message.id))"
            }.joined(separator: "\n")
        case .vaultTasks(let title, let tasks):
            guard !tasks.isEmpty else { return "\(title): none" }
            return "\(title):\n" + tasks.map { "- " + VaultTaskFormatter.line($0) }.joined(separator: "\n")
        case .calendar, .memories:
            // The listing the model needs is in the message's content or modelContent.
            return ""
        case .mailCleanup(let groups):
            guard !groups.isEmpty else { return "" }
            return "Mailing-list senders:\n" + groups.map { group in
                let state = group.outcome ?? group.rule.map { "rule: \($0.rawValue)" } ?? group.suggestion.map { "suggested: \($0.rawValue)" } ?? "undecided"
                return "- \(group.name) <\(group.address)>, \(group.messages.count) messages, \(state)"
            }.joined(separator: "\n")
        }
    }
}

/// One tool call shown in the transcript ("Searched …", "Read …").
public struct ToolStep: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case awaitingApproval, running, done, failed }

    public var id: String
    public var tool: String
    /// The query or URL, for display.
    public var subject: String
    public var status: Status
    public var error: String?
    public var sources: [SourceRef]
    /// For writes: what will happen, shown on the approval card.
    public var approvalSummary: String?

    public init(
        id: String, tool: String, subject: String, status: Status = .running, error: String? = nil,
        sources: [SourceRef] = [], approvalSummary: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.subject = subject
        self.status = status
        self.error = error
        self.sources = sources
        self.approvalSummary = approvalSummary
    }
}

/// A scheduled command or prompt (e.g. "/brief" on weekdays at 07:30).
@Model
public final class Automation {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// When it was last switched on; scheduled slots before this never run.
    public var enabledAt: Date
    /// A slash command ("/brief") or a plain prompt; always runs in Chat mode.
    public var command: String
    /// JSON-encoded `AutomationTrigger`.
    public var triggerData: Data
    public var notify: Bool
    public var createdAt: Date
    public var lastRunAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \AutomationRun.automation)
    public var runs: [AutomationRun]

    public init(name: String, command: String, trigger: AutomationTrigger, enabled: Bool = false, notify: Bool = true) {
        id = UUID()
        self.name = name
        self.enabled = enabled
        enabledAt = .now
        self.command = command
        triggerData = (try? JSONEncoder().encode(trigger)) ?? Data()
        self.notify = notify
        createdAt = .now
        runs = []
    }

    public var trigger: AutomationTrigger {
        get { (try? JSONDecoder().decode(AutomationTrigger.self, from: triggerData)) ?? .onWake }
        set { triggerData = (try? JSONEncoder().encode(newValue)) ?? triggerData }
    }

    public var orderedRuns: [AutomationRun] {
        runs.sorted { $0.startedAt > $1.startedAt }
    }
}

@Model
public final class AutomationRun {
    public enum Status: String, Codable, Sendable { case running, succeeded, failed, needsApproval, skipped }

    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var statusRaw: String
    public var summary: String
    /// `Conversation.id` of the chat the run produced.
    public var conversationID: UUID?
    public var automation: Automation?

    public init(conversationID: UUID?) {
        id = UUID()
        startedAt = .now
        statusRaw = Status.running.rawValue
        summary = ""
        self.conversationID = conversationID
    }

    public var status: Status {
        get { Status(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }
}

public enum CompanionSchema {
    public static let models: [any PersistentModel.Type] = [
        Conversation.self, StoredMessage.self, Automation.self, AutomationRun.self,
    ]
}
