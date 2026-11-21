import EventKit
import Foundation

/// EventKit-backed calendars and reminders (everything synced to macOS: iCloud, Google, Exchange …).
/// `hiddenCalendars` holds calendar / list identifiers the user excluded in Settings.
public actor EventKitStore: CalendarStore {
    public static let shared = EventKitStore()

    private let store = EKEventStore()
    public private(set) var hiddenCalendars: Set<String> = []

    public init() {}

    public func setHiddenCalendars(_ ids: Set<String>) {
        hiddenCalendars = ids
    }

    // MARK: Access

    public static var eventsAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    public static var remindersAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    public static var eventsDenied: Bool { [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .event)) }
    public static var remindersDenied: Bool { [.denied, .restricted].contains(EKEventStore.authorizationStatus(for: .reminder)) }

    /// Shows the macOS permission prompts (once each).
    public func requestAccess() async -> (events: Bool, reminders: Bool) {
        let events = (try? await store.requestFullAccessToEvents()) ?? false
        let reminders = (try? await store.requestFullAccessToReminders()) ?? false
        return (events, reminders)
    }

    // MARK: Calendars

    public func calendars() -> [CalendarInfo] {
        guard Self.eventsAuthorized else { return [] }
        return store.calendars(for: .event).map(Self.info).sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    public func reminderLists() -> [CalendarInfo] {
        guard Self.remindersAuthorized else { return [] }
        return store.calendars(for: .reminder).map(Self.info).sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        CalendarInfo(
            id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source?.title ?? "",
            allowsWrites: calendar.allowsContentModifications, colorHex: hex(calendar.cgColor)
        )
    }

    private static func hex(_ color: CGColor?) -> String? {
        guard let color, let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
            let parts = rgb.components, parts.count >= 3
        else { return nil }
        return String(format: "#%02X%02X%02X", Int(parts[0] * 255), Int(parts[1] * 255), Int(parts[2] * 255))
    }

    /// Calendars new events can go into (visible and writable), the default first.
    public func writableCalendars() -> [CalendarInfo] {
        guard Self.eventsAuthorized else { return [] }
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return visibleEventCalendars.filter(\.allowsContentModifications).map(Self.info)
            .sorted { ($0.id == defaultID ? 0 : 1, $0.source, $0.title) < ($1.id == defaultID ? 0 : 1, $1.source, $1.title) }
    }

    private var visibleEventCalendars: [EKCalendar] {
        store.calendars(for: .event).filter { !hiddenCalendars.contains($0.calendarIdentifier) }
    }

    private var visibleReminderLists: [EKCalendar] {
        store.calendars(for: .reminder).filter { !hiddenCalendars.contains($0.calendarIdentifier) }
    }

    // MARK: Events

    public func events(from: Date, to: Date) throws -> [CalendarEvent] {
        guard Self.eventsAuthorized else { throw PersonalDataError.accessDenied("your calendars") }
        let calendars = visibleEventCalendars
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).map(Self.event).sorted { $0.start < $1.start }
    }

    public func createEvent(title: String, start: Date, end: Date, calendar: String?, location: String?, notes: String?) throws -> CalendarEvent {
        guard Self.eventsAuthorized else { throw PersonalDataError.accessDenied("your calendars") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.calendar = try writableCalendar(named: calendar, type: .event)
        try store.save(event, span: .thisEvent, commit: true)
        return Self.event(event)
    }

    /// From the calendar card's form: a calendar by identifier, optionally all-day.
    public func createEvent(title: String, start: Date, end: Date, isAllDay: Bool, calendarID: String?, location: String?) throws -> CalendarEvent {
        guard Self.eventsAuthorized else { throw PersonalDataError.accessDenied("your calendars") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.location = location
        if let calendarID, let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications {
            event.calendar = calendar
        } else {
            event.calendar = try writableCalendar(named: nil, type: .event)
        }
        try store.save(event, span: .thisEvent, commit: true)
        return Self.event(event)
    }

    /// Only used to undo an event just added from the card.
    public func deleteEvent(id: String) throws {
        guard let event = store.event(withIdentifier: id) else { throw PersonalDataError.notFound("Event") }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    public func moveEvent(id: String, start: Date, end: Date) throws -> CalendarEvent {
        guard Self.eventsAuthorized else { throw PersonalDataError.accessDenied("your calendars") }
        guard let event = store.event(withIdentifier: id) else { throw PersonalDataError.notFound("Event") }
        guard event.calendar.allowsContentModifications else { throw PersonalDataError.invalid("That calendar is read-only.") }
        event.startDate = start
        event.endDate = end
        try store.save(event, span: .thisEvent, commit: true)
        return Self.event(event)
    }

    private static func event(_ event: EKEvent) -> CalendarEvent {
        let me = event.attendees?.first { $0.isCurrentUser }
        let participation: CalendarEvent.Participation = switch me?.participantStatus {
        case .accepted?: .accepted
        case .tentative?: .tentative
        case .declined?: .declined
        case .pending?: .pending
        default: .none
        }
        return CalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "(no title)",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendar: event.calendar?.title ?? "",
            location: event.location,
            notes: event.notes.map { String($0.prefix(500)) },
            organizer: event.organizer?.name,
            attendeeCount: event.attendees?.count ?? 0,
            participation: participation,
            isRecurring: event.hasRecurrenceRules,
            colorHex: hex(event.calendar?.cgColor)
        )
    }

    // MARK: Reminders

    public func reminders(list: String?, includeCompleted: Bool) async throws -> [ReminderItem] {
        guard Self.remindersAuthorized else { throw PersonalDataError.accessDenied("your reminders") }
        var lists = visibleReminderLists
        if let list {
            lists = lists.filter { $0.title.localizedCaseInsensitiveCompare(list) == .orderedSame }
            guard !lists.isEmpty else { throw PersonalDataError.notFound("Reminder list “\(list)”") }
        }
        let predicate = includeCompleted
            ? store.predicateForReminders(in: lists)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        // Convert inside the callback: EKReminder isn't Sendable.
        let fetched: [ReminderItem] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: ($0 ?? []).map(Self.reminder)) }
        }
        return fetched.sorted {
            ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title)
        }
    }

    public func createReminder(title: String, due: Date?, dueHasTime: Bool, list: String?) throws -> ReminderItem {
        guard Self.remindersAuthorized else { throw PersonalDataError.accessDenied("your reminders") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = try writableCalendar(named: list, type: .reminder)
        if let due {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: due)
            if dueHasTime {
                components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            reminder.dueDateComponents = components
        }
        try store.save(reminder, commit: true)
        return Self.reminder(reminder)
    }

    public func reminder(id: String) throws -> ReminderItem? {
        guard Self.remindersAuthorized else { throw PersonalDataError.accessDenied("your reminders") }
        return (store.calendarItem(withIdentifier: id) as? EKReminder).map(Self.reminder)
    }

    public func setReminderCompleted(id: String, _ completed: Bool) throws -> ReminderItem {
        let reminder = try existingReminder(id)
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
        return Self.reminder(reminder)
    }

    public func setReminderDue(id: String, due: Date?, hasTime: Bool) throws -> ReminderItem {
        let reminder = try existingReminder(id)
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
            if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        } else {
            reminder.dueDateComponents = nil
        }
        try store.save(reminder, commit: true)
        return Self.reminder(reminder)
    }

    public func deleteReminder(id: String) throws {
        try store.remove(try existingReminder(id), commit: true)
    }

    private func existingReminder(_ id: String) throws -> EKReminder {
        guard Self.remindersAuthorized else { throw PersonalDataError.accessDenied("your reminders") }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw PersonalDataError.notFound("Reminder")
        }
        guard reminder.calendar.allowsContentModifications else { throw PersonalDataError.invalid("That list is read-only.") }
        return reminder
    }

    private static func reminder(_ reminder: EKReminder) -> ReminderItem {
        let components = reminder.dueDateComponents
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "(no title)",
            due: components.flatMap { Calendar.current.date(from: $0) },
            dueHasTime: components?.hour != nil,
            list: reminder.calendar?.title ?? "",
            isCompleted: reminder.isCompleted,
            notes: reminder.notes.map { String($0.prefix(300)) }
        )
    }

    // MARK: Helpers

    private func writableCalendar(named name: String?, type: EKEntityType) throws -> EKCalendar {
        let candidates = (type == .event ? visibleEventCalendars : visibleReminderLists).filter(\.allowsContentModifications)
        if let name {
            guard let match = candidates.first(where: { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw PersonalDataError.notFound("\(type == .event ? "Calendar" : "Reminder list") “\(name)”")
            }
            return match
        }
        let fallback = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        if let fallback, !hiddenCalendars.contains(fallback.calendarIdentifier) { return fallback }
        guard let first = candidates.first else {
            throw PersonalDataError.invalid("No writable \(type == .event ? "calendar" : "reminder list") is visible.")
        }
        return first
    }
}
