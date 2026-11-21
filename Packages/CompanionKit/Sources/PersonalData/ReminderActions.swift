import Foundation

/// Quick due-date choices for a reminder row ("Today", "Tomorrow", "Next Week", "No Due Date").
public enum ReminderDueChoice: String, CaseIterable, Sendable, Identifiable {
    case today, tomorrow, nextWeek, none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next Week"
        case .none: "No Due Date"
        }
    }

    /// The new due date; keeps the time of day if the reminder had one. "Next week" is next Monday.
    public func date(keepingTimeOf current: ReminderItem, now: Date = .now, calendar: Calendar = .current) -> (Date?, Bool) {
        let today = calendar.startOfDay(for: now)
        let day: Date
        switch self {
        case .none: return (nil, false)
        case .today: day = today
        case .tomorrow: day = calendar.date(byAdding: .day, value: 1, to: today)!
        case .nextWeek:
            day = calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? today
        }
        guard current.dueHasTime, let due = current.due else { return (day, false) }
        let time = calendar.dateComponents([.hour, .minute], from: due)
        return (calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day), true)
    }
}
