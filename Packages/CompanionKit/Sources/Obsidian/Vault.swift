import CryptoKit
import Foundation

/// An Obsidian vault: a folder of Markdown notes. Found via Obsidian's own vault list.
public struct Vault: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    /// Open in Obsidian right now (from Obsidian's vault list).
    public var isOpen: Bool = false

    public var id: String { path }
    public var root: URL { URL(filePath: path, directoryHint: .isDirectory) }

    public init(name: String, path: String, isOpen: Bool = false) {
        self.name = name
        self.path = path
        self.isOpen = isOpen
    }

    /// Vaults Obsidian knows about (`~/Library/Application Support/obsidian/obsidian.json`).
    public static func detect(configURL: URL = URL.applicationSupportDirectory.appending(path: "obsidian/obsidian.json")) -> [Vault] {
        struct Config: Decodable {
            struct Entry: Decodable {
                var path: String
                var open: Bool?
            }
            var vaults: [String: Entry]
        }
        guard let data = try? Data(contentsOf: configURL), let config = try? JSONDecoder().decode(Config.self, from: data) else { return [] }
        return config.vaults.values
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Vault(name: URL(filePath: $0.path).lastPathComponent, path: $0.path, isOpen: $0.open ?? false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `obsidian://open?vault=…&file=…` — opens the note in Obsidian.
    public func url(for relativePath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        let file = relativePath.hasSuffix(".md") ? String(relativePath.dropLast(3)) : relativePath
        components.queryItems = [URLQueryItem(name: "vault", value: name), URLQueryItem(name: "file", value: file)]
        return components.url
    }
}

/// The parts of a vault's `.obsidian` settings the assistant follows.
public struct VaultSettings: Sendable, Hashable {
    /// Daily notes: folder (relative, "" = root), Moment.js format, optional template note.
    public var dailyFolder: String
    public var dailyFormat: String
    public var dailyTemplate: String?
    /// Tasks plugin: append "✅ YYYY-MM-DD" when ticking.
    public var setDoneDate: Bool
    /// Day Planner plugin: the heading its timeline reads from the daily note.
    public var plannerHeading: String
    public var plannerHeadingLevel: Int

    public init(
        dailyFolder: String = "", dailyFormat: String = "YYYY-MM-DD", dailyTemplate: String? = nil, setDoneDate: Bool = true,
        plannerHeading: String = "Day planner", plannerHeadingLevel: Int = 1
    ) {
        self.dailyFolder = dailyFolder
        self.dailyFormat = dailyFormat
        self.dailyTemplate = dailyTemplate
        self.setDoneDate = setDoneDate
        self.plannerHeading = plannerHeading
        self.plannerHeadingLevel = plannerHeadingLevel
    }

    public static func read(_ vault: Vault) -> VaultSettings {
        var settings = VaultSettings()
        let config = vault.root.appending(path: ".obsidian")
        if let data = try? Data(contentsOf: config.appending(path: "daily-notes.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            settings.dailyFolder = (json["folder"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            if let format = json["format"] as? String, !format.isEmpty { settings.dailyFormat = format }
            if let template = json["template"] as? String, !template.isEmpty { settings.dailyTemplate = template }
        }
        if let data = try? Data(contentsOf: config.appending(path: "plugins/obsidian-tasks-plugin/data.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            settings.setDoneDate = json["setDoneDate"] as? Bool ?? true
        }
        if let data = try? Data(contentsOf: config.appending(path: "plugins/obsidian-day-planner/data.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            if let heading = json["plannerHeading"] as? String, !heading.isEmpty { settings.plannerHeading = heading }
            if let level = json["plannerHeadingLevel"] as? Int, (1...6).contains(level) { settings.plannerHeadingLevel = level }
        }
        return settings
    }

    /// Relative path of the daily note for `date` (Moment tokens YYYY, YY, MM, M, DD, D, ddd, dddd, MMM, MMMM).
    public func dailyNotePath(for date: Date, calendar: Calendar = .current) -> String {
        let name = Self.format(dailyFormat, date: date, calendar: calendar)
        return (dailyFolder.isEmpty ? "" : dailyFolder + "/") + name + ".md"
    }

    static func format(_ moment: String, date: Date, calendar: Calendar) -> String {
        let tokens: [(String, String)] = [
            ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
            ("DD", "dd"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"), ("HH", "HH"), ("mm", "mm"),
        ]
        var pattern = ""
        var index = moment.startIndex
        var literal = ""
        func flushLiteral() {
            guard !literal.isEmpty else { return }
            pattern += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
            literal = ""
        }
        outer: while index < moment.endIndex {
            if moment[index] == "[", let close = moment[index...].firstIndex(of: "]") {
                literal += moment[moment.index(after: index)..<close]
                index = moment.index(after: close)
                continue
            }
            for (token, replacement) in tokens where moment[index...].hasPrefix(token) {
                flushLiteral()
                pattern += replacement
                index = moment.index(index, offsetBy: token.count)
                continue outer
            }
            let character = moment[index]
            if character.isLetter { literal.append(character) } else { flushLiteral(); pattern.append(character) }
            index = moment.index(after: index)
        }
        flushLiteral()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

public enum VaultError: LocalizedError, Equatable {
    case outsideVault(String)
    case notFound(String)
    case changedOnDisk(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .outsideVault(let path): "“\(path)” is outside the vault."
        case .notFound(let path): "No note “\(path)” in the vault."
        case .changedOnDisk(let path): "“\(path)” changed while I was editing it. Nothing was written; try again."
        case .invalid(let message): message
        }
    }
}

/// One note: frontmatter (raw YAML) and body.
public struct Note: Sendable, Hashable {
    public var path: String
    public var frontmatter: String?
    public var body: String
    public var modified: Date

    public var title: String {
        URL(filePath: path).deletingPathExtension().lastPathComponent
    }

    /// Splits "---\n…\n---\n" off the top.
    public static func split(_ text: String) -> (frontmatter: String?, body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return (nil, normalized) }
        let rest = normalized.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") ?? rest.range(of: "\n---", options: .anchored.union(.backwards)) else { return (nil, normalized) }
        return (String(rest[..<end.lowerBound]), String(rest[end.upperBound...]))
    }
}

/// Reads and safely writes notes inside one vault. Writes: only Markdown, only inside the vault,
/// never deleting or renaming, atomic, and only if the file didn't change since it was read.
public struct NoteStore: Sendable {
    public let vault: Vault
    public let settings: VaultSettings
    static let skipped: Set<String> = [".obsidian", ".git", ".trash", "node_modules"]

    public init(vault: Vault, settings: VaultSettings? = nil) {
        self.vault = vault
        self.settings = settings ?? VaultSettings.read(vault)
    }

    // MARK: Paths

    /// A vault-relative path → file URL, refusing anything that would leave the vault (`..`,
    /// absolute paths, symlinks pointing out).
    public func resolve(_ relativePath: String) throws -> URL {
        let raw = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.hasPrefix("/"), !raw.hasPrefix("~") else { throw VaultError.outsideVault(relativePath) }
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty, !cleaned.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw VaultError.outsideVault(relativePath)
        }
        guard !cleaned.split(separator: "/").contains(where: { Self.skipped.contains(String($0)) }) else {
            throw VaultError.outsideVault(relativePath)
        }
        let root = vault.root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appending(path: cleaned).standardizedFileURL
        // Existing parts may be symlinks: resolve what exists and check again.
        var check = url
        while !FileManager.default.fileExists(atPath: check.path), check.path.count > root.path.count {
            check = check.deletingLastPathComponent()
        }
        let resolved = check.resolvingSymlinksInPath().path
        guard resolved == root.path || resolved.hasPrefix(root.path + "/") else { throw VaultError.outsideVault(relativePath) }
        return url
    }

    func relative(_ url: URL) -> String {
        let root = vault.root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
    }

    // MARK: Reading

    /// All Markdown notes (relative paths), skipping Obsidian's config, git and trash.
    public func allNotes() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: vault.root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var notes: [String] = []
        for case let url as URL in enumerator {
            if Self.skipped.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "md" { notes.append(relative(url)) }
        }
        return notes.sorted()
    }

    public func read(_ relativePath: String) throws -> Note {
        var path = relativePath
        if !path.lowercased().hasSuffix(".md") { path += ".md" }
        var url = try resolve(path)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Obsidian links use the note name only: find it anywhere in the vault.
            let name = URL(filePath: path).lastPathComponent.lowercased()
            guard let match = allNotes().first(where: { URL(filePath: $0).lastPathComponent.lowercased() == name }) else {
                throw VaultError.notFound(relativePath)
            }
            path = match
            url = try resolve(match)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let (frontmatter, body) = Note.split(text)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return Note(path: path, frontmatter: frontmatter, body: body, modified: modified)
    }

    public struct SearchHit: Sendable, Hashable {
        public var path: String
        public var snippet: String
        public var score: Int
    }

    /// Notes whose name or text contain the query words; names count more, snippets show context.
    public func search(_ query: String, limit: Int = 10) -> [SearchHit] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for path in allNotes() {
            guard let url = try? resolve(path), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            let name = path.lowercased()
            var score = 0
            for word in words {
                if name.contains(word) { score += 5 }
                let count = lower.components(separatedBy: word).count - 1
                score += min(count, 5)
                if count == 0 && !name.contains(word) { score -= 3 }
            }
            guard score > 0 else { continue }
            hits.append(SearchHit(path: path, snippet: Self.snippet(text, around: words), score: score))
        }
        return Array(hits.sorted { ($0.score, $1.path) > ($1.score, $0.path) }.prefix(limit))
    }

    static func snippet(_ text: String, around words: [String]) -> String {
        let body = Note.split(text).body
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.first { line in words.contains { line.lowercased().contains($0) } } ?? lines.first ?? ""
        return line.count > 160 ? String(line.prefix(160)) + "…" : line
    }

    // MARK: Writing

    /// Replaces a note's content if it is still what was read (same hash). Atomic.
    func write(_ relativePath: String, content: String, expecting previous: String?) throws {
        let url = try resolve(relativePath)
        guard url.pathExtension.lowercased() == "md" else { throw VaultError.invalid("Only Markdown notes can be written.") }
        let current = try? String(contentsOf: url, encoding: .utf8)
        if Self.hash(current) != Self.hash(previous) { throw VaultError.changedOnDisk(relativePath) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: [.atomic])
    }

    static func hash(_ text: String?) -> String? {
        text.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
    }

    /// Appends a line to the daily note (created from the daily-note template if missing, else empty).
    @discardableResult
    public func appendToDailyNote(_ text: String, date: Date = .now, calendar: Calendar = .current) throws -> String {
        let path = settings.dailyNotePath(for: date, calendar: calendar)
        let url = try resolve(path)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        var content = existing ?? template() ?? ""
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let entry = text.split(whereSeparator: \.isNewline).enumerated().map { index, line in
            index == 0 ? "- \(time) \(line)" : "  \(line)"
        }.joined(separator: "\n")
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += entry + "\n"
        try write(path, content: content, expecting: existing)
        return path
    }

    func dailyTemplateText() -> String? { template() }

    private func template() -> String? {
        guard let template = settings.dailyTemplate, let note = try? read(template) else { return nil }
        return [note.frontmatter.map { "---\n\($0)\n---\n" }, note.body].compactMap(\.self).joined()
    }

    /// Creates a new note; never overwrites (a number is added to the name if it exists).
    @discardableResult
    public func createNote(title: String, text: String, folder: String = "Inbox", frontmatter: [String: String] = [:]) throws -> String {
        let safeTitle = title
            .replacingOccurrences(of: #"[\\/:*?"<>|#^\[\]]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeTitle.isEmpty else { throw VaultError.invalid("A note needs a title.") }
        let base = (folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty ? "" : folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/") + safeTitle
        var path = base + ".md"
        var number = 2
        while FileManager.default.fileExists(atPath: try resolve(path).path) {
            path = "\(base) \(number).md"
            number += 1
        }
        var content = ""
        if !frontmatter.isEmpty {
            content += "---\n" + frontmatter.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n---\n"
        }
        content += text.hasSuffix("\n") ? text : text + "\n"
        try write(path, content: content, expecting: nil)
        return path
    }
}
