import Foundation

public struct CalendarInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var source: String
    public var allowsWrites: Bool

    public init(id: String, title: String, source: String, allowsWrites: Bool) {
        self.id = id
        self.title = title
        self.source = source
        self.allowsWrites = allowsWrites
    }
}

public struct CalendarEvent: Sendable, Hashable, Identifiable {
    public enum Participation: String, Sendable, Hashable { case accepted, tentative, declined, pending, none }

    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendar: String
    public var location: String?
    public var notes: String?
    public var organizer: String?
    public var attendeeCount: Int
    /// The user's own response to an invitation.
    public var participation: Participation
    public var isRecurring: Bool

    public init(
        id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, calendar: String,
        location: String? = nil, notes: String? = nil, organizer: String? = nil, attendeeCount: Int = 0,
        participation: Participation = .none, isRecurring: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.organizer = organizer
        self.attendeeCount = attendeeCount
        self.participation = participation
        self.isRecurring = isRecurring
    }

    /// Declined invitations and all-day entries don't block time.
    public var blocksTime: Bool { !isAllDay && participation != .declined }
}

public struct ReminderItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var due: Date?
    /// Whether `due` includes a time of day.
    public var dueHasTime: Bool
    public var list: String
    public var isCompleted: Bool
    public var notes: String?

    public init(id: String, title: String, due: Date? = nil, dueHasTime: Bool = false, list: String, isCompleted: Bool = false, notes: String? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.list = list
        self.isCompleted = isCompleted
        self.notes = notes
    }
}

public enum PersonalDataError: LocalizedError, Equatable {
    case accessDenied(String)
    case notFound(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied(let what): "No access to \(what). Allow it in Settings → Assistant."
        case .notFound(let what): "\(what) not found."
        case .invalid(let message): message
        }
    }
}

/// Calendars and reminders, behind a protocol so tests and the app can use different backends.
public protocol CalendarStore: Sendable {
    func calendars() async -> [CalendarInfo]
    func reminderLists() async -> [CalendarInfo]
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
    func createEvent(title: String, start: Date, end: Date, calendar: String?, location: String?, notes: String?) async throws -> CalendarEvent
    func moveEvent(id: String, start: Date, end: Date) async throws -> CalendarEvent
    func reminders(list: String?, includeCompleted: Bool) async throws -> [ReminderItem]
    func createReminder(title: String, due: Date?, dueHasTime: Bool, list: String?) async throws -> ReminderItem
    func completeReminder(id: String) async throws -> ReminderItem
    /// Current state of one reminder (nil if it was deleted elsewhere).
    func reminder(id: String) async throws -> ReminderItem?
    func setReminderCompleted(id: String, _ completed: Bool) async throws -> ReminderItem
    func setReminderDue(id: String, due: Date?, hasTime: Bool) async throws -> ReminderItem
    func deleteReminder(id: String) async throws
}

extension CalendarStore {
    public func completeReminder(id: String) async throws -> ReminderItem {
        try await setReminderCompleted(id: id, true)
    }
}
