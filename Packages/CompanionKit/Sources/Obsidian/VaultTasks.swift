import Foundation

/// A checklist item in a note, in the Tasks plugin's emoji format
/// (`- [ ] Pay rent 📅 2026-12-01 ⏫ #home`).
public struct VaultTask: Codable, Sendable, Hashable, Identifiable {
    public var vault: String
    public var path: String
    /// Zero-based line number when read; checked against `raw` before any change.
    public var line: Int
    public var raw: String
    public var text: String
    public var isDone: Bool
    public var due: Date?
    public var scheduled: Date?
    public var priority: Int
    public var tags: [String]

    public var id: String { "\(vault)|\(path)|\(line)" }

    /// Overdue or due/scheduled today.
    public func isDue(on day: Date = .now, calendar: Calendar = .current) -> Bool {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        return [due, scheduled].compactMap(\.self).contains { $0 < end }
    }
}

public enum VaultTaskParser {
    static var pattern: Regex<(Substring, Substring, Substring, Substring)> { /^(\s*)[-*+] \[(.)\] (.*)$/ }

    public static func tasks(in text: String, vault: String, path: String) -> [VaultTask] {
        var tasks: [VaultTask] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var inCode = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            guard !inCode, let match = try? pattern.wholeMatch(in: String(line)) else { continue }
            let status = String(match.output.2)
            let body = String(match.output.3)
            guard status != "-" else { continue }  // cancelled
            tasks.append(parse(body, raw: String(line), done: status.lowercased() == "x", vault: vault, path: path, line: index))
        }
        return tasks
    }

    static func parse(_ body: String, raw: String, done: Bool, vault: String, path: String, line: Int) -> VaultTask {
        func date(after marker: String) -> Date? {
            guard let range = body.range(of: marker) else { return nil }
            let rest = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return dayFormatter.date(from: String(rest.prefix(10)))
        }
        let priorities: [(String, Int)] = [("🔺", 3), ("⏫", 2), ("🔼", 1), ("🔽", -1), ("⏬", -2)]
        let priority = priorities.first { body.contains($0.0) }?.1 ?? 0
        let tags = body.split(separator: " ").filter { $0.hasPrefix("#") && $0.count > 1 }.map { String($0.dropFirst()) }
        // The readable text: up to the first Tasks marker.
        let markers = ["📅", "⏳", "🛫", "✅", "➕", "❌", "🔁", "🔺", "⏫", "🔼", "🔽", "⏬", "🆔", "⛔"]
        let cut = markers.compactMap { body.range(of: $0)?.lowerBound }.min() ?? body.endIndex
        let text = body[..<cut].trimmingCharacters(in: .whitespaces)
        return VaultTask(
            vault: vault, path: path, line: line, raw: raw, text: text.isEmpty ? body : text, isDone: done,
            due: date(after: "📅"), scheduled: date(after: "⏳"), priority: priority, tags: tags
        )
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The task line ticked or unticked, with the Tasks plugin's done date.
    static func toggled(_ raw: String, done: Bool, setDoneDate: Bool, today: Date) -> String {
        guard let match = try? pattern.wholeMatch(in: raw) else { return raw }
        let indent = String(match.output.1)
        let bullet = raw.drop { $0 == " " || $0 == "\t" }.prefix(1)
        var body = String(match.output.3)
        if done {
            if setDoneDate, !body.contains("✅") { body += " ✅ " + dayFormatter.string(from: today) }
        } else {
            body = body.replacingOccurrences(of: #"\s*✅ \d{4}-\d{2}-\d{2}"#, with: "", options: .regularExpression)
        }
        return "\(indent)\(bullet) [\(done ? "x" : " ")] \(body)"
    }
}

extension NoteStore {
    /// Every task in the vault (open ones first by due date).
    public func tasks(includeDone: Bool = false) -> [VaultTask] {
        var all: [VaultTask] = []
        for path in allNotes() {
            guard let url = try? resolve(path), let text = try? String(contentsOf: url, encoding: .utf8), text.contains("[") else { continue }
            all += VaultTaskParser.tasks(in: text, vault: vault.name, path: path).filter { includeDone || !$0.isDone }
        }
        return all.sorted { lhs, rhs in
            let left = lhs.due ?? lhs.scheduled ?? .distantFuture, right = rhs.due ?? rhs.scheduled ?? .distantFuture
            return (left, -lhs.priority, lhs.path, lhs.line) < (right, -rhs.priority, rhs.path, rhs.line)
        }
    }

    /// Ticks (or unticks) a task — only if its line is still exactly what was read.
    @discardableResult
    public func setDone(_ task: VaultTask, _ done: Bool, today: Date = .now) throws -> VaultTask {
        let url = try resolve(task.path)
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        var index = task.line
        if !(lines.indices.contains(index) && lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == task.raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // The note was edited above the task: find the line by its text, if it is unique.
            let matches = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == task.raw.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard matches.count == 1 else { throw VaultError.changedOnDisk(task.path) }
            index = matches[0]
        }
        let carriage = lines[index].hasSuffix("\r")
        let updated = VaultTaskParser.toggled(lines[index].trimmingCharacters(in: CharacterSet(charactersIn: "\r")), done: done, setDoneDate: settings.setDoneDate, today: today)
        lines[index] = updated + (carriage ? "\r" : "")
        try write(task.path, content: lines.joined(separator: "\n"), expecting: text)
        var result = VaultTaskParser.parse(
            String((try? VaultTaskParser.pattern.wholeMatch(in: updated))?.output.3 ?? ""),
            raw: updated, done: done, vault: task.vault, path: task.path, line: index
        )
        result.line = index
        return result
    }
}
