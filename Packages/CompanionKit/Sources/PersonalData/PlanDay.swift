import Foundation

/// One line of a /planday list: what, which day, and an optional time.
public struct PlanItem: Sendable, Hashable {
    public var title: String
    /// Start of the day it's for.
    public var day: Date
    /// The time of day, if one was written.
    public var at: Date?

    public init(title: String, day: Date, at: Date? = nil) {
        self.title = title
        self.day = day
        self.at = at
    }
}

/// Turns a typed list into plan items — no model, so it's instant and predictable:
/// bullets are optional, a time anywhere in the line ("14:00", "14.30", "14 Uhr", "2pm") sets the
/// time, "morgen:" / "tomorrow:" / "übermorgen:" at the start moves the line to that day.
public enum PlanDayParser {
    public static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> [PlanItem] {
        let today = calendar.startOfDay(for: now)
        return text.components(separatedBy: .newlines).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Bullets, numbers and empty checkboxes.
            line = line.replacingOccurrences(of: #"^([-*•–]|\d+[.)]|\[ ?\])\s*(\[ ?\]\s*)?"#, with: "", options: .regularExpression)
            guard !line.isEmpty else { return nil }

            var offset = 0
            let dayWords: [(String, Int)] = [("übermorgen", 2), ("uebermorgen", 2), ("day after tomorrow", 2), ("morgen", 1), ("tomorrow", 1), ("heute", 0), ("today", 0)]
            for (word, days) in dayWords {
                if let range = line.range(of: #"^\#(word)\s*[:,\-–]?\s+"#, options: [.regularExpression, .caseInsensitive]) {
                    offset = days
                    line.removeSubrange(range)
                    break
                }
            }
            let day = calendar.date(byAdding: .day, value: offset, to: today)!

            var at: Date?
            let patterns = [
                #"(?:\b(?:um|at|@)\s*)?\b([01]?\d|2[0-3])[:.]([0-5]\d)\b(?:\s*uhr\b)?"#,
                #"(?:\b(?:um|at|@)\s*)?\b([01]?\d|2[0-3])\s*uhr\b"#,
                #"(?:\b(?:um|at|@)\s*)?\b(1[0-2]|0?[1-9])(?::([0-5]\d))?\s*(am|pm)\b"#,
            ]
            for (index, pattern) in patterns.enumerated() {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                    let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
                else { continue }
                func group(_ number: Int) -> String? {
                    guard number < match.numberOfRanges, let range = Range(match.range(at: number), in: line) else { return nil }
                    return String(line[range])
                }
                var hour = Int(group(1) ?? "") ?? 0
                let minute = Int(group(2) ?? "") ?? 0
                if index == 2, let suffix = group(3)?.lowercased() {
                    if suffix == "pm", hour < 12 { hour += 12 }
                    if suffix == "am", hour == 12 { hour = 0 }
                }
                at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
                if let range = Range(match.range, in: line) { line.removeSubrange(range) }
                break
            }
            let title = line.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–"))
            guard !title.isEmpty else { return nil }
            return PlanItem(title: title, day: day, at: at)
        }
    }
}
