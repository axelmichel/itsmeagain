import Commands
import Foundation
import Persistence
import PersonalData
import SwiftData

/// Native calendar commands: instant listings straight from EventKit, no model involved.
extension AppModel {
    static let calendarHandlers: Set<String> = ["today", "tomorrow", "week", "agenda", "cal", "free", "reminders"]

    func runCalendarCommand(_ handler: String, input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: today)! }

        // Validate arguments before anything is written to the conversation.
        var range: (Date, Date)?
        var freeMinutes = 0
        switch handler {
        case "today": range = (today, day(1))
        case "tomorrow": range = (day(1), day(2))
        case "week": range = (today, day(7))
        case "agenda":
            guard let date = Self.parseDay(input.arguments) else { return .failed("Usage: /agenda <date> — e.g. 24.12., tomorrow, next Friday") }
            let start = calendar.startOfDay(for: date)
            range = (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        case "cal":
            var start = today
            if !input.arguments.isEmpty {
                guard let date = Self.parseDay(input.arguments) else { return .failed("Usage: /cal [date or month] — e.g. 24.12., December, next Friday") }
                start = calendar.startOfDay(for: date)
            }
            range = (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        case "free":
            guard let first = input.positional.first, let minutes = DurationParser.minutes(first) else {
                return .failed("Usage: /free <30m|1h|1h30> [day]")
            }
            freeMinutes = minutes
            let rest = input.positional.dropFirst().joined(separator: " ")
            let start = rest.isEmpty ? today : (Self.parseDay(rest).map { calendar.startOfDay(for: $0) } ?? today)
            range = (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        default:
            break
        }

        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        if conversation.messages.isEmpty { conversation.title = text }
        conversation.append(role: .user, content: text, task: .chat)
        let reply = conversation.append(role: .assistant, content: "", task: .chat)
        try? context.save()

        let list = input.arguments.isEmpty ? nil : input.arguments
        chat.run(in: conversation, context: context) { [self] in
            do {
                try await ensureCalendarAccess(reminders: handler == "today" || handler == "reminders")
                let store = EventKitStore.shared
                switch handler {
                case "reminders":
                    let items = try await store.reminders(list: list, includeCompleted: false)
                    if items.isEmpty { reply.content = "_No open reminders._" }
                    reply.attachments = [.reminders(title: list.map { "Open reminders in \($0)" } ?? "Open reminders", items: Self.overdueFirst(items))]
                case "free":
                    let (from, to) = range!
                    let events = try await store.events(from: from, to: to)
                    let slots = FreeSlotFinder.find(busy: events, from: max(from, .now), to: to, minimumMinutes: freeMinutes)
                    reply.content = slots.isEmpty
                        ? "No free \(freeMinutes) minutes on \(ToolDate.day(from)) between 09:00 and 18:00."
                        : "**Free on \(ToolDate.day(from))** (≥ \(freeMinutes) min)\n\n" + slots.map {
                            "- \(ToolDate.time($0.start))–\(ToolDate.time($0.end))"
                        }.joined(separator: "\n")
                default:
                    // A calendar card for the eye; the plain listing for the model's follow-ups.
                    let (from, to) = range!
                    reply.modelContent = AgendaFormatter.agenda(try await store.events(from: from, to: to), from: from, to: to, markdown: false)
                    let style: CalendarCardStyle = handler == "week" ? .week : handler == "cal" ? .month : .day
                    var attachments: [MessageAttachment] = [.calendar(style: style, date: from)]
                    if handler == "today", let due = try await dueReminders(before: to), !due.isEmpty {
                        attachments.append(.reminders(title: "Reminders due", items: due))
                    }
                    reply.attachments = attachments
                }
            } catch {
                reply.errorText = error.localizedDescription
            }
        }
        return .handled
    }

    /// Asks macOS for access the first time; afterwards only reports.
    func ensureCalendarAccess(reminders: Bool) async throws {
        if !EventKitStore.eventsAuthorized && !EventKitStore.eventsDenied
            || reminders && !EventKitStore.remindersAuthorized && !EventKitStore.remindersDenied {
            _ = await EventKitStore.shared.requestAccess()
        }
        guard EventKitStore.eventsAuthorized else { throw PersonalDataError.accessDenied("your calendars") }
    }

    /// "24.12.", "Dezember", "2026-11-24", "tomorrow", "next Friday", …
    static func parseDay(_ text: String) -> Date? {
        DayParser.parse(text)
    }

    /// Open reminders due before `date` (overdue first); nil without reminder access.
    func dueReminders(before date: Date) async throws -> [ReminderItem]? {
        guard EventKitStore.remindersAuthorized else { return nil }
        let items = try await EventKitStore.shared.reminders(list: nil, includeCompleted: false)
        return Self.overdueFirst(items.filter { ($0.due ?? .distantFuture) < date })
    }

    static func overdueFirst(_ items: [ReminderItem]) -> [ReminderItem] {
        let today = Calendar.current.startOfDay(for: .now)
        let overdue = items.filter { ($0.due ?? .distantFuture) < today }
        return overdue + items.filter { !overdue.contains($0) }.prefix(60)
    }
}
