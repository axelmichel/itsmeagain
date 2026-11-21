import CompanionCore
import Foundation
import Synchronization
import Testing

@testable import PersonalData
@testable import Tools

let berlin: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
}()

func at(_ text: String) -> Date { ToolDate.parse(text, calendar: berlin)!.date }

/// In-memory calendar for tests.
final class FakeCalendarStore: CalendarStore, @unchecked Sendable {
    let state = Mutex<(events: [CalendarEvent], reminders: [ReminderItem])>(([], []))

    init(events: [CalendarEvent] = [], reminders: [ReminderItem] = []) {
        state.withLock { $0 = (events, reminders) }
    }

    func calendars() async -> [CalendarInfo] { [CalendarInfo(id: "w", title: "Work", source: "iCloud", allowsWrites: true)] }
    func reminderLists() async -> [CalendarInfo] { [CalendarInfo(id: "r", title: "Reminders", source: "iCloud", allowsWrites: true)] }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        state.withLock { $0.events.filter { $0.start < to && $0.end > from } }
    }

    func createEvent(title: String, start: Date, end: Date, calendar: String?, location: String?, notes: String?) async throws -> CalendarEvent {
        let event = CalendarEvent(id: "new-\(title)", title: title, start: start, end: end, calendar: calendar ?? "Work", location: location, notes: notes)
        state.withLock { $0.events.append(event) }
        return event
    }

    func moveEvent(id: String, start: Date, end: Date) async throws -> CalendarEvent {
        try state.withLock {
            guard let index = $0.events.firstIndex(where: { $0.id == id }) else { throw PersonalDataError.notFound("Event") }
            $0.events[index].start = start
            $0.events[index].end = end
            return $0.events[index]
        }
    }

    func reminders(list: String?, includeCompleted: Bool) async throws -> [ReminderItem] {
        state.withLock { $0.reminders.filter { (includeCompleted || !$0.isCompleted) && (list == nil || $0.list == list) } }
    }

    func createReminder(title: String, due: Date?, dueHasTime: Bool, list: String?) async throws -> ReminderItem {
        let item = ReminderItem(id: "r-\(title)", title: title, due: due, dueHasTime: dueHasTime, list: list ?? "Reminders")
        state.withLock { $0.reminders.append(item) }
        return item
    }

    func reminder(id: String) async throws -> ReminderItem? {
        state.withLock { $0.reminders.first { $0.id == id } }
    }

    func setReminderCompleted(id: String, _ completed: Bool) async throws -> ReminderItem {
        try update(id) { $0.isCompleted = completed }
    }

    func setReminderDue(id: String, due: Date?, hasTime: Bool) async throws -> ReminderItem {
        try update(id) {
            $0.due = due
            $0.dueHasTime = hasTime
        }
    }

    func deleteReminder(id: String) async throws {
        try state.withLock {
            guard let index = $0.reminders.firstIndex(where: { $0.id == id }) else { throw PersonalDataError.notFound("Reminder") }
            $0.reminders.remove(at: index)
        }
    }

    private func update(_ id: String, _ change: (inout ReminderItem) -> Void) throws -> ReminderItem {
        try state.withLock {
            guard let index = $0.reminders.firstIndex(where: { $0.id == id }) else { throw PersonalDataError.notFound("Reminder") }
            change(&$0.reminders[index])
            return $0.reminders[index]
        }
    }
}

@Suite struct ToolDateTests {
    @Test func parsesFormatsAndKeywords() {
        #expect(ToolDate.parse("2026-11-24", calendar: berlin) == .init(date: at("2026-11-24T00:00"), hasTime: false))
        #expect(ToolDate.parse("2026-11-24T09:30", calendar: berlin)?.hasTime == true)
        #expect(ToolDate.parse("2026-11-24 09:30:15", calendar: berlin)?.hasTime == true)
        #expect(ToolDate.parse("2026-11-24T08:30:00Z", calendar: berlin)?.date == at("2026-11-24T09:30"), "explicit UTC is converted")
        let now = at("2026-11-21T10:00")
        #expect(ToolDate.parse("tomorrow", now: now, calendar: berlin)?.date == at("2026-11-22"))
        #expect(ToolDate.parse("Morgen", now: now, calendar: berlin)?.date == at("2026-11-22"))
        #expect(ToolDate.parse("next week", calendar: berlin) == nil)
    }
}

@Suite struct FreeSlotTests {
    @Test func findsGapsWithinWorkingHours() {
        let events = [
            CalendarEvent(id: "1", title: "Standup", start: at("2026-11-24T09:00"), end: at("2026-11-24T09:15"), calendar: "W"),
            CalendarEvent(id: "2", title: "Review", start: at("2026-11-24T10:00"), end: at("2026-11-24T11:00"), calendar: "W"),
            CalendarEvent(id: "3", title: "Overlap", start: at("2026-11-24T10:30"), end: at("2026-11-24T12:00"), calendar: "W"),
            CalendarEvent(id: "4", title: "Declined", start: at("2026-11-24T14:00"), end: at("2026-11-24T15:00"), calendar: "W", participation: .declined),
            CalendarEvent(id: "5", title: "Holiday", start: at("2026-11-24"), end: at("2026-11-25"), isAllDay: true, calendar: "W"),
        ]
        let slots = FreeSlotFinder.find(busy: events, from: at("2026-11-24"), to: at("2026-11-25"), minimumMinutes: 30, calendar: berlin)
        #expect(slots == [
            .init(start: at("2026-11-24T09:15"), end: at("2026-11-24T10:00")),
            .init(start: at("2026-11-24T12:00"), end: at("2026-11-24T18:00")),
        ])
        let long = FreeSlotFinder.find(busy: events, from: at("2026-11-24"), to: at("2026-11-26"), minimumMinutes: 120, calendar: berlin)
        #expect(long == [
            .init(start: at("2026-11-24T12:00"), end: at("2026-11-24T18:00")),
            .init(start: at("2026-11-25T09:00"), end: at("2026-11-25T18:00")),
        ])
    }
}

@Suite struct CalendarToolTests {
    let store = FakeCalendarStore(
        events: [
            CalendarEvent(id: "e1", title: "Dentist", start: at("2026-11-24T15:00"), end: at("2026-11-24T16:00"), calendar: "Private", location: "Main St 1"),
            CalendarEvent(id: "e2", title: "Team offsite", start: at("2026-11-25"), end: at("2026-11-26"), isAllDay: true, calendar: "Work"),
            CalendarEvent(id: "e3", title: "1:1", start: at("2026-11-25T09:00"), end: at("2026-11-25T09:30"), calendar: "Work", participation: .pending),
        ],
        reminders: [
            ReminderItem(id: "r1", title: "Pay rent", due: at("2026-11-20"), list: "Home"),
            ReminderItem(id: "r2", title: "Book flights", due: at("2026-11-30"), list: "Travel"),
            ReminderItem(id: "r3", title: "Done thing", list: "Home", isCompleted: true),
        ]
    )

    func tool<T>(_ make: (any CalendarStore) -> T) -> T { make(store) }

    @Test func listsEventsByDay() async throws {
        var events = CalendarEventsTool(store: store)
        events.calendar = berlin
        let output = try await events.run(["from": "2026-11-24", "to": "2026-11-25"])
        #expect(output.content.hasPrefix("""
            Tue, 24 Nov 2026
              15:00–16:00 · Dentist · 📍 Main St 1 · [Private]
            Wed, 25 Nov 2026
              all day · Team offsite · [Work]
              09:00–09:30 · 1:1 · (not answered) · [Work]
            """))
        #expect(output.content.contains("Dentist = e1"))
        await #expect(throws: ToolError.self) { try await events.run(["from": "next week"]) }
        await #expect(throws: ToolError.self) { try await events.run(["from": "2026-11-25", "to": "2026-11-24"]) }
    }

    @Test func createEventDescribesAndCreates() async throws {
        var create = CreateEventTool(store: store)
        create.calendar = berlin
        #expect(create.effect == .write && create.dataClass == .private)
        let args: JSONValue = ["title": "Lunch with Anna", "start": "2026-11-26T12:30", "calendar": "Private"]
        #expect(create.describe(args) == "Create event “Lunch with Anna” on Thu, 26 Nov 2026, 12:30–13:30 in Private")
        let output = try await create.run(args)
        #expect(output.content.contains("Lunch with Anna"))
        #expect(store.state.withLock { $0.events.contains { $0.title == "Lunch with Anna" && $0.end == at("2026-11-26T13:30") } })
        await #expect(throws: ToolError.self) { try await create.run(["title": "x", "start": "2026-11-26"]) }
    }

    @Test func remindersFilterAndCreate() async throws {
        var list = RemindersTool(store: store)
        list.calendar = berlin
        let due = try await list.run(["due_by": "2026-11-24"])
        #expect(due.content.contains("Pay rent"))
        #expect(due.content.contains("(overdue)"))
        #expect(!due.content.contains("Book flights"))
        #expect(!due.content.contains("Done thing"))

        var create = CreateReminderTool(store: store)
        create.calendar = berlin
        #expect(create.describe(["title": "Call mum", "due": "2026-11-27T18:00"]) == "Create reminder “Call mum”, due Fri, 27 Nov 2026 18:00")
        _ = try await create.run(["title": "Call mum", "due": "2026-11-27"])
        #expect(store.state.withLock { $0.reminders.contains { $0.title == "Call mum" && $0.dueHasTime == false } })
    }

    @Test func writesGoThroughApprovalInTheLoop() async throws {
        let provider = RoundScriptProvider([
            [.toolCall(ToolCall(id: "c1", name: "create_reminder", arguments: ["title": "Buy milk"])), .done(nil)],
            [.textDelta("ok"), .done(nil)],
        ])
        let tools = CalendarToolbox.tools(store: store, events: true, reminders: true)
        let loop = ToolLoop(provider: provider, tools: tools, policy: ToolPolicy(providerIsLocal: true) { _ in false })
        _ = try await loop.run(ChatRequest(model: "m", messages: [.user("remind me")])).collect()
        #expect(!store.state.withLock { $0.reminders.contains { $0.title == "Buy milk" } }, "denied → not created")

        let remote = ToolLoop(provider: RoundScriptProvider([[.done(nil)]]), tools: tools, policy: ToolPolicy(providerIsLocal: false) { _ in true })
        #expect(remote.permittedTools.isEmpty, "calendar tools never reach cloud models")
    }
}

@Suite struct DurationParserTests {
    @Test(arguments: [("30m", 30), ("1h", 60), ("1h30", 90), ("1h30m", 90), ("90", 90), ("45 min", 45), ("2 Std", 120), ("2hours", 120)])
    func parses(text: String, minutes: Int) {
        #expect(DurationParser.minutes(text) == minutes)
    }

    @Test(arguments: ["", "0", "soon", "h", "1d"])
    func rejects(text: String) {
        #expect(DurationParser.minutes(text) == nil)
    }
}

@Suite struct ReminderActionTests {
    @Test func dueChoicesKeepTimeOfDay() {
        let now = at("2026-11-21T10:00")  // Saturday
        let timed = ReminderItem(id: "a", title: "Call", due: at("2026-11-20T18:30"), dueHasTime: true, list: "L")
        let dateOnly = ReminderItem(id: "b", title: "Pay", due: at("2026-11-20"), list: "L")

        #expect(ReminderDueChoice.today.date(keepingTimeOf: timed, now: now, calendar: berlin) == (at("2026-11-21T18:30"), true))
        #expect(ReminderDueChoice.tomorrow.date(keepingTimeOf: dateOnly, now: now, calendar: berlin) == (at("2026-11-22"), false))
        #expect(ReminderDueChoice.nextWeek.date(keepingTimeOf: dateOnly, now: now, calendar: berlin) == (at("2026-11-23"), false), "next Monday")
        #expect(ReminderDueChoice.none.date(keepingTimeOf: timed, now: now, calendar: berlin) == (nil, false))
    }

    @Test func storeTogglesMovesAndDeletes() async throws {
        let store = FakeCalendarStore(reminders: [ReminderItem(id: "r1", title: "Pay rent", due: at("2026-11-20"), list: "Home")])
        #expect(try await store.setReminderCompleted(id: "r1", true).isCompleted)
        #expect(try await store.setReminderCompleted(id: "r1", false).isCompleted == false, "undo")
        #expect(try await store.setReminderDue(id: "r1", due: at("2026-11-23"), hasTime: false).due == at("2026-11-23"))
        try await store.deleteReminder(id: "r1")
        #expect(try await store.reminder(id: "r1") == nil)
        await #expect(throws: PersonalDataError.notFound("Reminder")) { try await store.deleteReminder(id: "r1") }
    }

    @Test func remindersRoundTripAsJSON() throws {
        let item = ReminderItem(id: "x", title: "T", due: at("2026-11-23T09:00"), dueHasTime: true, list: "L")
        #expect(try JSONDecoder().decode(ReminderItem.self, from: JSONEncoder().encode(item)) == item)
    }
}
