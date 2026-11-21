import Foundation

/// Fills a prompt command's template.
///
/// - `$ARGUMENTS`: everything after the command name
/// - `$1`…`$9`: positional arguments (empty if missing)
/// - `{{today}}`: today as a long date ("Saturday, 21 November 2026")
/// - `{{now}}`: date and time
/// - `{{date}}`, `{{date:+1d}}`, `{{date:-2w}}`, `{{date:+1m}}`: ISO dates (yyyy-MM-dd), e.g. for daily notes
public enum TemplateExpander {
    public static func expand(
        _ template: String,
        input: CommandInput,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var result = template.replacingOccurrences(of: "$ARGUMENTS", with: input.arguments)
        for index in stride(from: 9, through: 1, by: -1) {
            let value = index <= input.positional.count ? input.positional[index - 1] : ""
            result = result.replacingOccurrences(of: "$\(index)", with: value)
        }
        result = result.replacingOccurrences(
            of: "{{today}}",
            with: now.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        )
        result = result.replacingOccurrences(
            of: "{{now}}",
            with: now.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        )
        // {{date}} and {{date:±N(d|w|m)}}
        let pattern = /\{\{date(?::([+-]\d+)([dwm]))?\}\}/
        result = result.replacing(pattern) { match in
            var date = now
            if let amount = match.output.1.flatMap({ Int($0) }), let unit = match.output.2 {
                let component: Calendar.Component = unit == "d" ? .day : unit == "w" ? .weekOfYear : .month
                date = calendar.date(byAdding: component, value: amount, to: now) ?? now
            }
            return isoDate(date, calendar: calendar)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isoDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
