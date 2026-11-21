import Foundation

/// Dates in tool arguments: ISO 8601 ("2026-11-24", "2026-11-24T09:30", with or without zone/seconds)
/// or the keywords today / tomorrow / yesterday. Interpreted in the given calendar's time zone.
public enum ToolDate {
    public struct Parsed: Equatable, Sendable {
        public var date: Date
        public var hasTime: Bool
    }

    public static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> Parsed? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        let today = calendar.startOfDay(for: now)
        switch value {
        case "today", "heute": return Parsed(date: today, hasTime: false)
        case "tomorrow", "morgen": return calendar.date(byAdding: .day, value: 1, to: today).map { Parsed(date: $0, hasTime: false) }
        case "yesterday", "gestern": return calendar.date(byAdding: .day, value: -1, to: today).map { Parsed(date: $0, hasTime: false) }
        default: break
        }
        // With an explicit zone or Z.
        let withZone = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            withZone.formatOptions = options
            if let date = withZone.date(from: text.trimmingCharacters(in: .whitespaces)) { return Parsed(date: date, hasTime: true) }
        }
        // Local time.
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for (format, hasTime) in [
            ("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true),
            ("yyyy-MM-dd HH:mm:ss", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false),
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return Parsed(date: date, hasTime: hasTime) }
        }
        return nil
    }

    /// For tool output: "Mon 24 Nov 2026" / "Mon 24 Nov 09:30".
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(
            Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated).day().month(.abbreviated).year()
        )
    }

    /// Always 24-hour "HH:mm": unambiguous for models and users alike.
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// For the model: an unambiguous local timestamp with the zone offset.
    public static func iso(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Gaps between busy events inside working hours, per day.
public enum FreeSlotFinder {
    public struct Slot: Equatable, Sendable {
        public var start: Date
        public var end: Date
    }

    public static func find(
        busy events: [CalendarEvent],
        from: Date,
        to: Date,
        minimumMinutes: Int,
        workStartHour: Int = 9,
        workEndHour: Int = 18,
        calendar: Calendar = .current
    ) -> [Slot] {
        let busy = events.filter(\.blocksTime)
            .map { ($0.start, $0.end) }
            .sorted { $0.0 < $1.0 }
        var slots: [Slot] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            guard let workStart = calendar.date(bySettingHour: workStartHour, minute: 0, second: 0, of: day),
                let workEnd = calendar.date(bySettingHour: workEndHour, minute: 0, second: 0, of: day)
            else { break }
            var cursor = max(workStart, from)
            let limit = min(workEnd, to)
            for (start, end) in busy where end > cursor && start < limit {
                if start > cursor, start.timeIntervalSince(cursor) >= Double(minimumMinutes * 60) {
                    slots.append(Slot(start: cursor, end: start))
                }
                cursor = max(cursor, end)
            }
            if limit > cursor, limit.timeIntervalSince(cursor) >= Double(minimumMinutes * 60) {
                slots.append(Slot(start: cursor, end: limit))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return slots
    }
}

/// Plain-text listings shared by tools (for the model) and native commands (Markdown for the user).
public enum AgendaFormatter {
    public static func eventLine(_ event: CalendarEvent, calendar: Calendar = .current, markdown: Bool = false) -> String {
        let time = event.isAllDay
            ? "all day"
            : "\(ToolDate.time(event.start, calendar: calendar))–\(ToolDate.time(event.end, calendar: calendar))"
        var parts = [markdown ? "**\(time)**" : time, event.title]
        if let location = event.location, !location.isEmpty { parts.append("📍 \(location)") }
        switch event.participation {
        case .tentative: parts.append("(tentative)")
        case .pending: parts.append("(not answered)")
        case .declined: parts.append("(declined)")
        default: break
        }
        if !markdown { parts.append("[\(event.calendar)]") }
        return parts.joined(separator: " · ")
    }

    /// Events grouped by day.
    public static func agenda(_ events: [CalendarEvent], from: Date, to: Date, calendar: Calendar = .current, markdown: Bool = false) -> String {
        var lines: [String] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let onDay = events.filter { $0.start < next && $0.end > day }.sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
            let heading = ToolDate.day(day, calendar: calendar)
            lines.append(markdown ? "**\(heading)**" : heading)
            if onDay.isEmpty {
                lines.append(markdown ? "- _Nothing scheduled_" : "  (nothing)")
            } else {
                lines += onDay.map { (markdown ? "- " : "  ") + eventLine($0, calendar: calendar, markdown: markdown) }
            }
            day = next
        }
        return lines.joined(separator: "\n")
    }

    public static func reminderLine(_ reminder: ReminderItem, now: Date = .now, calendar: Calendar = .current) -> String {
        var line = reminder.title
        if let due = reminder.due {
            let overdue = !reminder.isCompleted && due < (reminder.dueHasTime ? now : calendar.startOfDay(for: now))
            line += " — due \(ToolDate.day(due, calendar: calendar))" + (reminder.dueHasTime ? " \(ToolDate.time(due, calendar: calendar))" : "")
            if overdue { line += " (overdue)" }
        }
        line += " [\(reminder.list)]"
        if reminder.isCompleted { line += " ✓" }
        return line
    }
}

/// "30m", "1h", "1h30", "90", "45 min", "2 Std" → minutes.
public enum DurationParser {
    public static func minutes(_ text: String) -> Int? {
        let value = text.lowercased().replacingOccurrences(of: " ", with: "")
        if let plain = Int(value) { return plain > 0 ? plain : nil }
        let pattern = /^(?:(\d+)(?:h|hr|hrs|hours?|std))?(?:(\d+)(?:m|min|mins|minutes?)?)?$/
        guard let match = value.wholeMatch(of: pattern) else { return nil }
        let hours = match.output.1.flatMap { Int($0) } ?? 0
        let minutes = match.output.2.flatMap { Int($0) } ?? 0
        let total = hours * 60 + minutes
        return total > 0 ? total : nil
    }
}
