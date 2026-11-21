import Foundation

/// When an automation runs.
public enum AutomationTrigger: Codable, Sendable, Hashable {
    /// At a time of day on the given weekdays (Calendar weekday numbers: 1 = Sunday … 7 = Saturday).
    case daily(hour: Int, minute: Int, weekdays: Set<Int>)
    /// Every `minutes` minutes.
    case interval(minutes: Int)
    /// Each time the Mac wakes from sleep.
    case onWake

    public static let weekdaysOnly: Set<Int> = [2, 3, 4, 5, 6]
    public static let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
}

/// Pure schedule math; the clock and calendar are injected so it's testable.
public enum Schedule {
    /// The first fire time strictly after `date` (nil for `onWake` or an empty weekday set).
    public static func nextFire(_ trigger: AutomationTrigger, after date: Date, calendar: Calendar = .current) -> Date? {
        switch trigger {
        case .onWake:
            return nil
        case .interval(let minutes):
            return date.addingTimeInterval(TimeInterval(max(minutes, 1) * 60))
        case .daily(let hour, let minute, let weekdays):
            guard !weekdays.isEmpty else { return nil }
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            components.second = 0
            var candidate = date
            // At most 8 days ahead covers every weekday combination.
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: candidate, matching: components, matchingPolicy: .nextTime) else {
                    return nil
                }
                if weekdays.contains(calendar.component(.weekday, from: next)) { return next }
                candidate = next
            }
            return nil
        }
    }

    /// Whether a scheduled trigger fired since the automation last ran (or was enabled) — once, even if
    /// several fire times were missed while the Mac slept.
    public static func isDue(
        _ trigger: AutomationTrigger,
        lastRun: Date?,
        enabledAt: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let reference = max(lastRun ?? enabledAt, enabledAt)
        switch trigger {
        case .onWake:
            return false
        case .interval(let minutes):
            return now.timeIntervalSince(reference) >= TimeInterval(max(minutes, 1) * 60)
        case .daily:
            guard let fire = nextFire(trigger, after: reference, calendar: calendar) else { return false }
            return fire <= now
        }
    }

    /// Short human description ("Weekdays at 07:30", "Every 15 min", "After waking").
    public static func describe(_ trigger: AutomationTrigger, calendar: Calendar = .current) -> String {
        switch trigger {
        case .onWake:
            return "After waking"
        case .interval(let minutes):
            return minutes % 60 == 0 ? "Every \(minutes / 60) h" : "Every \(minutes) min"
        case .daily(let hour, let minute, let weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            let days: String
            switch weekdays {
            case AutomationTrigger.everyDay: days = "Daily"
            case AutomationTrigger.weekdaysOnly: days = "Weekdays"
            case [1, 7]: days = "Weekends"
            default:
                let symbols = calendar.shortWeekdaySymbols
                days = weekdays.sorted { (($0 + 5) % 7) < (($1 + 5) % 7) }  // Monday first
                    .map { symbols[$0 - 1] }
                    .joined(separator: ", ")
            }
            return "\(days) at \(time)"
        }
    }
}

/// An automation's "Command or prompt" field: one step per line (a /command or a prompt), run in
/// order in the same conversation. Empty lines and lines starting with `#` are skipped.
public enum AutomationSteps {
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
