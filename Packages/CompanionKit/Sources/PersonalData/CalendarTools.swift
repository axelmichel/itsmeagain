import CompanionCore
import Foundation
import Tools

/// Tool names, shared with TaskProfile defaults and the app.
public enum PersonalToolName {
    public static let calendarEvents = "calendar_events"
    public static let freeSlots = "free_slots"
    public static let createEvent = "create_event"
    public static let moveEvent = "move_event"
    public static let reminders = "reminders"
    public static let createReminder = "create_reminder"
    public static let completeReminder = "complete_reminder"

    public static let calendarAndReminders = [calendarEvents, freeSlots, createEvent, moveEvent, reminders, createReminder, completeReminder]
}

private func requiredDate(_ arguments: JSONValue, _ key: String, calendar: Calendar) throws -> ToolDate.Parsed {
    let text = try arguments.requiredString(key)
    guard let parsed = ToolDate.parse(text, calendar: calendar) else {
        throw ToolError.invalidArgument("“\(key)” must be ISO 8601 (e.g. 2026-11-24 or 2026-11-24T09:30), today or tomorrow.")
    }
    return parsed
}

private let dateHint = "Local time, ISO 8601: 2026-11-24 or 2026-11-24T09:30 (also: today, tomorrow)."

public struct CalendarEventsTool: Tool {
    public let store: any CalendarStore
    public var calendar: Calendar = .current
    public init(store: any CalendarStore) { self.store = store }

    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: PersonalToolName.calendarEvents,
            description: "List the user's calendar events between two dates (inclusive days). Returns times, titles, locations, calendars and event ids.",
            parameters: [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": .string("First day. \(dateHint)")],
                    "to": ["type": "string", "description": .string("Last day (inclusive). Defaults to `from`. \(dateHint)")],
                ],
                "required": ["from"],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let from = calendar.startOfDay(for: try requiredDate(arguments, "from", calendar: calendar).date)
        let lastDay = try arguments["to"]?.stringValue.map { _ in try requiredDate(arguments, "to", calendar: calendar).date } ?? from
        guard let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)), to > from else {
            throw ToolError.invalidArgument("“to” must not be before “from”.")
        }
        guard calendar.dateComponents([.day], from: from, to: to).day ?? 0 <= 62 else {
            throw ToolError.invalidArgument("Ask for at most two months at a time.")
        }
        let events = try await store.events(from: from, to: to)
        var text = AgendaFormatter.agenda(events, from: from, to: to, calendar: calendar)
        if !events.isEmpty {
            text += "\n\nEvent ids (for move_event): " + events.map { "\($0.title) = \($0.id)" }.joined(separator: "; ")
        }
        return ToolOutput(content: text)
    }
}

public struct FreeSlotsTool: Tool {
    public let store: any CalendarStore
    public var calendar: Calendar = .current
    public init(store: any CalendarStore) { self.store = store }

    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: PersonalToolName.freeSlots,
            description: "Find free time in the user's calendar: gaps of at least `minutes` within working hours.",
            parameters: [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": .string("First day. \(dateHint)")],
                    "to": ["type": "string", "description": .string("Last day (inclusive). Defaults to `from`.")],
                    "minutes": ["type": "integer", "description": "Minimum length of a free slot"],
                    "start_hour": ["type": "integer", "description": "Working day starts (default 9)"],
                    "end_hour": ["type": "integer", "description": "Working day ends (default 18)"],
                ],
                "required": ["from", "minutes"],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let first = try requiredDate(arguments, "from", calendar: calendar).date
        let from = calendar.startOfDay(for: first)
        let lastDay = try arguments["to"]?.stringValue.map { _ in try requiredDate(arguments, "to", calendar: calendar).date } ?? from
        guard let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)) else {
            throw ToolError.invalidArgument("Invalid range.")
        }
        guard let minutes = arguments["minutes"]?.intValue, minutes > 0 else { throw ToolError.missingArgument("minutes") }
        let startHour = arguments["start_hour"]?.intValue ?? 9
        let endHour = arguments["end_hour"]?.intValue ?? 18
        // Never offer slots in the past.
        let begin = max(from, first > from ? first : from, .now > from && .now < to ? .now : from)
        let events = try await store.events(from: from, to: to)
        let slots = FreeSlotFinder.find(busy: events, from: begin, to: to, minimumMinutes: minutes, workStartHour: startHour, workEndHour: endHour, calendar: calendar)
        guard !slots.isEmpty else { return ToolOutput(content: "No free slot of \(minutes) minutes between \(startHour):00 and \(endHour):00.") }
        let lines = slots.map { "\(ToolDate.day($0.start, calendar: calendar)) \(ToolDate.time($0.start, calendar: calendar))–\(ToolDate.time($0.end, calendar: calendar))" }
        return ToolOutput(content: "Free slots:\n" + lines.joined(separator: "\n"))
    }
}

public struct CreateEventTool: Tool {
    public let store: any CalendarStore
    public var calendar: Calendar = .current
    public init(store: any CalendarStore) { self.store = store }

    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { .write }

    public var spec: ToolSpec {
        ToolSpec(
            name: PersonalToolName.createEvent,
            description: "Create a calendar event. The user is asked to approve it first.",
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": .string("Start, local time. \(dateHint)")],
                    "end": ["type": "string", "description": "End, local time. Defaults to one hour after start."],
                    "calendar": ["type": "string", "description": "Calendar name (optional; default calendar otherwise)"],
                    "location": ["type": "string"],
                    "notes": ["type": "string"],
                ],
                "required": ["title", "start"],
            ]
        )
    }

    func times(_ arguments: JSONValue) throws -> (Date, Date) {
        let start = try requiredDate(arguments, "start", calendar: calendar)
        guard start.hasTime else { throw ToolError.invalidArgument("“start” needs a time, e.g. 2026-11-24T09:30.") }
        let end = try arguments["end"]?.stringValue.map { _ in try requiredDate(arguments, "end", calendar: calendar).date }
            ?? start.date.addingTimeInterval(3600)
        guard end > start.date else { throw ToolError.invalidArgument("“end” must be after “start”.") }
        return (start.date, end)
    }

    public func describe(_ arguments: JSONValue) -> String {
        let title = arguments["title"]?.stringValue ?? "?"
        guard let (start, end) = try? times(arguments) else { return "Create event “\(title)”" }
        var text = "Create event “\(title)” on \(ToolDate.day(start, calendar: calendar)), \(ToolDate.time(start, calendar: calendar))–\(ToolDate.time(end, calendar: calendar))"
        if let name = arguments["calendar"]?.stringValue { text += " in \(name)" }
        if let location = arguments["location"]?.stringValue { text += " at \(location)" }
        return text
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let (start, end) = try times(arguments)
        let event = try await store.createEvent(
            title: try arguments.requiredString("title"), start: start, end: end,
            calendar: arguments["calendar"]?.stringValue, location: arguments["location"]?.stringValue,
            notes: arguments["notes"]?.stringValue
        )
        return ToolOutput(content: "Created: \(ToolDate.day(event.start, calendar: calendar)) \(AgendaFormatter.eventLine(event, calendar: calendar)) (id \(event.id))")
    }
}

public struct MoveEventTool: Tool {
    public let store: any CalendarStore
    public var calendar: Calendar = .current
    public init(store: any CalendarStore) { self.store = store }

    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { .write }

    public var spec: ToolSpec {
        ToolSpec(
            name: PersonalToolName.moveEvent,
            description: "Move an existing event (id from calendar_events) to a new time. The user is asked to approve it first.",
            parameters: [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "start": ["type": "string", "description": .string("New start. \(dateHint)")],
                    "end": ["type": "string", "description": "New end"],
                ],
                "required": ["id", "start", "end"],
            ]
        )
    }

    public func describe(_ arguments: JSONValue) -> String {
        guard let start = arguments["start"]?.stringValue.flatMap({ ToolDate.parse($0, calendar: calendar) }),
            let end = arguments["end"]?.stringValue.flatMap({ ToolDate.parse($0, calendar: calendar) })
        else { return "Move an event" }
        return "Move event to \(ToolDate.day(start.date, calendar: calendar)), \(ToolDate.time(start.date, calendar: calendar))–\(ToolDate.time(end.date, calendar: calendar))"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let start = try requiredDate(arguments, "start", calendar: calendar).date
        let end = try requiredDate(arguments, "end", calendar: calendar).date
        guard end > start else { throw ToolError.invalidArgument("“end” must be after “start”.") }
        let event = try await store.moveEvent(id: try arguments.requiredString("id"), start: start, end: end)
        return ToolOutput(content: "Moved: \(ToolDate.day(event.start, calendar: calendar)) \(AgendaFormatter.eventLine(event, calendar: calendar))")
    }
}

public struct RemindersTool: Tool {
    public let store: any CalendarStore
    public var calendar: Calendar = .current
    public init(store: any CalendarStore) { self.store = store }

    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: PersonalToolName.reminders,
            description: "List the user's open reminders (optionally one list, only those due by a date, or including completed).",
            parameters: [
                "type": "object",
                "properties": [
                    "list": ["type": "string", "description": "Reminder list name (optional)"],
                    "due_by": ["type": "string", "description": .string("Only reminders due on or before this day. \(dateHint)")],
                    "include_completed": ["type": "boolean"],
                ],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        var items = try await store.reminders(list: arguments["list"]?.stringValue, includeCompleted: arguments["include_completed"] == true)
        if arguments["due_by"]?.stringValue != nil {
            let day = try requiredDate(arguments, "due_by", calendar: calendar).date
            guard let limit = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { throw ToolError.invalidArgument("Invalid due_by.") }
            items = items.filter { ($0.due ?? .distantFuture) < limit }
        }
        guard !items.isEmpty else { return ToolOutput(content: "No matching reminders.") }
        let lines = items.prefix(50).map { "- \(AgendaFormatter.reminderLine($0, calendar: calendar)) (id \($0.id))" }
        return ToolOutput(content: lines.joined(separator: "\n"))
    }
}

public struct CreateReminderTool: Tool {
    public let store: any CalendarStore
    public var calendar: Calendar = .current
    public init(store: any CalendarStore) { self.store = store }

    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { .write }

    public var spec: ToolSpec {
        ToolSpec(
            name: PersonalToolName.createReminder,
            description: "Create a reminder, optionally with a due date/time and list.",
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "due": ["type": "string", "description": .string("Optional due day or time. \(dateHint)")],
                    "list": ["type": "string", "description": "Reminder list name (optional)"],
                ],
                "required": ["title"],
            ]
        )
    }

    public func describe(_ arguments: JSONValue) -> String {
        var text = "Create reminder “\(arguments["title"]?.stringValue ?? "?")”"
        if let due = arguments["due"]?.stringValue.flatMap({ ToolDate.parse($0, calendar: calendar) }) {
            text += ", due \(ToolDate.day(due.date, calendar: calendar))" + (due.hasTime ? " \(ToolDate.time(due.date, calendar: calendar))" : "")
        }
        if let list = arguments["list"]?.stringValue { text += " in \(list)" }
        return text
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let due = try arguments["due"]?.stringValue.map { _ in try requiredDate(arguments, "due", calendar: calendar) }
        let item = try await store.createReminder(
            title: try arguments.requiredString("title"), due: due?.date, dueHasTime: due?.hasTime ?? false,
            list: arguments["list"]?.stringValue
        )
        return ToolOutput(content: "Created reminder: \(AgendaFormatter.reminderLine(item, calendar: calendar))")
    }
}

public struct CompleteReminderTool: Tool {
    public let store: any CalendarStore
    public init(store: any CalendarStore) { self.store = store }

    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { .write }

    public var spec: ToolSpec {
        ToolSpec(
            name: PersonalToolName.completeReminder,
            description: "Mark a reminder (id from the reminders tool) as done.",
            parameters: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]
        )
    }

    public func describe(_ arguments: JSONValue) -> String { "Mark a reminder as done" }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let item = try await store.completeReminder(id: try arguments.requiredString("id"))
        return ToolOutput(content: "Done: \(item.title)")
    }
}

public enum CalendarToolbox {
    /// All calendar and reminder tools for a store.
    public static func tools(store: any CalendarStore, events: Bool, reminders: Bool) -> [any Tool] {
        var tools: [any Tool] = []
        if events { tools += [CalendarEventsTool(store: store), FreeSlotsTool(store: store), CreateEventTool(store: store), MoveEventTool(store: store)] }
        if reminders { tools += [RemindersTool(store: store), CreateReminderTool(store: store), CompleteReminderTool(store: store)] }
        return tools
    }
}
