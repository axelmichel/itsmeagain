import Foundation

/// A timed entry for the Day Planner plugin's timeline.
public struct DayPlanEntry: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var title: String

    public init(start: Date, end: Date, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}

extension NoteStore {
    /// Writes today's events under the Day Planner heading (`- [ ] 09:00 - 10:00 Title`, only those
    /// not there yet) and the brief into a "Morning brief" section that is replaced on every run.
    /// Everything else in the daily note stays as it is.
    @discardableResult
    public func updateDailyNote(plan: [DayPlanEntry], brief: String?, date: Date = .now, calendar: Calendar = .current) throws -> String {
        let path = settings.dailyNotePath(for: date, calendar: calendar)
        let url = try resolve(path)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        var lines = (existing ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines == [""] { lines = [] }

        if !plan.isEmpty {
            let heading = String(repeating: "#", count: settings.plannerHeadingLevel) + " " + settings.plannerHeading
            let entries = plan.sorted { $0.start < $1.start }.map { entry in
                "- [ ] \(Self.time(entry.start, calendar)) - \(Self.time(entry.end, calendar)) \(entry.title.replacingOccurrences(of: "\n", with: " "))"
            }
            if let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(heading) == .orderedSame }) {
                // The planner list ends at the next heading of any level (e.g. "## Morning brief").
                let sectionEnd = Self.sectionEnd(lines, after: headingIndex, anyLevel: true)
                let present = Set(lines[(headingIndex + 1)..<sectionEnd].map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                // Same entry ticked off ("- [x] …") also counts as present.
                let missing = entries.filter { entry in
                    !present.contains(entry.lowercased()) && !present.contains(entry.lowercased().replacingOccurrences(of: "- [ ]", with: "- [x]"))
                }
                // Each new entry goes before the first entry that starts later, so the note reads in time order.
                var end = sectionEnd
                for entry in missing {
                    let start = Self.startTime(entry) ?? "99:99"
                    var insertAt = end
                    while insertAt > headingIndex + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
                    if let later = ((headingIndex + 1)..<end).first(where: { Self.startTime(lines[$0]).map { $0 > start } ?? false }) {
                        insertAt = later
                    }
                    lines.insert(entry, at: insertAt)
                    end += 1
                }
            } else {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                lines += [heading, ""] + entries
            }
        }

        if let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
            let heading = "## Morning brief"
            let body = brief.components(separatedBy: "\n")
            if let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) {
                let sectionEnd = Self.sectionEnd(lines, after: headingIndex)
                lines.replaceSubrange((headingIndex + 1)..<sectionEnd, with: [""] + body + [""])
            } else {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                lines += [heading, ""] + body
            }
        }

        var content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") { content += "\n" }
        if existing == nil, let template = dailyTemplateText() { content = template + (template.hasSuffix("\n") ? "" : "\n") + content }
        try write(path, content: content, expecting: existing)
        return path
    }

    /// Index of the next heading of the same or a higher level (or the end).
    static func sectionEnd(_ lines: [String], after headingIndex: Int, anyLevel: Bool = false) -> Int {
        let level = anyLevel ? 6 : lines[headingIndex].prefix { $0 == "#" }.count
        var index = headingIndex + 1
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0, hashes <= level, line.dropFirst(hashes).first == " " { return index }
            index += 1
        }
        return lines.count
    }

    /// "- [ ] 09:30 - 10:00 …" → "09:30".
    static func startTime(_ line: String) -> String? {
        guard let match = line.firstMatch(of: /^\s*[-*] \[.\] (\d{1,2}:\d{2})/) else { return nil }
        let time = String(match.output.1)
        return time.count == 4 ? "0" + time : time
    }

    static func time(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

extension NoteStore {
    /// /planday into the daily note: timed tasks as Day Planner entries (30 min), the others as
    /// checkboxes in a "Todos" section. Lines already there aren't added again.
    @discardableResult
    public func addTodos(_ todos: [(title: String, at: Date?)], date: Date = .now, calendar: Calendar = .current) throws -> String {
        let timed = todos.compactMap { todo in todo.at.map { DayPlanEntry(start: $0, end: $0.addingTimeInterval(30 * 60), title: todo.title) } }
        var path = settings.dailyNotePath(for: date, calendar: calendar)
        if !timed.isEmpty { path = try updateDailyNote(plan: timed, brief: nil, date: date, calendar: calendar) }

        let untimed = todos.filter { $0.at == nil }.map { "- [ ] \($0.title)" }
        guard !untimed.isEmpty else { return path }
        let url = try resolve(path)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        var lines = (existing ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines == [""] { lines = [] }
        let heading = "## Todos"
        if let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) {
            let end = Self.sectionEnd(lines, after: headingIndex, anyLevel: true)
            let present = Set(lines[(headingIndex + 1)..<end].map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "- [x] ", with: "- [ ] ") })
            var insertAt = end
            while insertAt > headingIndex + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            lines.insert(contentsOf: untimed.filter { !present.contains($0) }, at: insertAt)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += [heading, ""] + untimed
        }
        var content = lines.joined(separator: "\n")
        if !content.hasSuffix("\n") { content += "\n" }
        try write(path, content: content, expecting: existing)
        return path
    }
}
