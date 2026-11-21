import Foundation

/// The vault's own rules from `CLAUDE.md`: topic folders under `second-brain/` and the allowed tags.
public struct VaultConventions: Sendable, Hashable {
    /// "second-brain/Local LLMs" …
    public var topicFolders: [String]
    /// "ai/local-llm", "youtube" …
    public var tags: [String]

    public init(topicFolders: [String] = [], tags: [String] = []) {
        self.topicFolders = topicFolders
        self.tags = tags
    }

    public static func read(_ store: NoteStore) -> VaultConventions {
        guard let text = try? String(contentsOf: try store.resolve("CLAUDE.md"), encoding: .utf8) else { return VaultConventions() }
        return parse(text, existing: Set(store.allFolders()))
    }

    static func parse(_ text: String, existing: Set<String> = []) -> VaultConventions {
        var folders: [String] = []
        // The "second-brain/" row of the folder table lists the topic folders in backticks.
        if let row = text.split(separator: "\n").first(where: { $0.contains("`second-brain/`") }) {
            for match in row.matches(of: /`([^`\/]+)\/`/) where match.output.1 != "second-brain" {
                folders.append("second-brain/" + match.output.1)
            }
        }
        // Folders that exist but aren't listed (added later) count too.
        folders += existing.filter { $0.hasPrefix("second-brain/") && $0.split(separator: "/").count == 2 && !folders.contains($0) }.sorted()

        var tags: [String] = []
        if let section = text.range(of: "## Tags") {
            let rest = text[section.upperBound...]
            let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
            for line in rest[..<end].split(separator: "\n") where line.hasPrefix("- ") {
                let names = line.matches(of: /`([^`]+)`/).map { String($0.output.1) }
                guard let first = names.first else { continue }
                if first.hasSuffix("/") {
                    tags += names.dropFirst().map { first + $0 }
                } else {
                    tags += names  // "lose:" tags without prefix
                }
            }
        }
        return VaultConventions(topicFolders: folders, tags: tags)
    }
}

/// Simple, line-based frontmatter access for the vault's own schemas (scalar keys and `tags:` lists).
public struct Frontmatter: Sendable, Hashable {
    public var lines: [String]

    public init(_ yaml: String?) {
        lines = (yaml ?? "").isEmpty ? [] : (yaml ?? "").components(separatedBy: "\n")
    }

    public var text: String { lines.joined(separator: "\n") }

    public func value(_ key: String) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(key + ":") }) else { return nil }
        let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2,
            let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        {
            return decoded
        }
        return value
    }

    public var tags: [String] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("tags:") }) else { return [] }
        var tags: [String] = []
        var index = start + 1
        while index < lines.count, lines[index].hasPrefix("  - ") || lines[index].hasPrefix("- ") {
            let raw = lines[index].trimmingCharacters(in: .whitespaces).dropFirst(2)
            let tag = raw.split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !tag.isEmpty { tags.append(tag) }
            index += 1
        }
        return tags
    }

    /// Sets a scalar (JSON-quoted); a new key goes after `after` (or at the end).
    public mutating func set(_ key: String, _ value: String, after: [String] = []) {
        let line = "\(key): " + (String(data: try! JSONEncoder().encode(value), encoding: .utf8) ?? "\"\"")
        if let index = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
            lines[index] = line
            return
        }
        let current = lines
        let anchor = after.compactMap { key in current.lastIndex { $0.hasPrefix(key + ":") } }.first
        lines.insert(line, at: anchor.map { $0 + 1 } ?? lines.count)
    }

    public mutating func setTags(_ tags: [String]) {
        let block = ["tags:"] + tags.map { "  - \($0)" }
        if let start = lines.firstIndex(where: { $0.hasPrefix("tags:") }) {
            var end = start + 1
            while end < lines.count, lines[end].hasPrefix("  - ") || lines[end].hasPrefix("- ") { end += 1 }
            lines.replaceSubrange(start..<end, with: block)
        } else {
            lines += block
        }
    }
}

/// A link line for a Related block: `[[Note]] — why it fits`.
public struct RelatedLink: Codable, Sendable, Hashable {
    public var note: String
    public var reason: String

    public init(note: String, reason: String) {
        self.note = note
        self.reason = reason
    }
}

public enum RelatedBlock {
    static let header = "> [!info]- Related"

    public static func make(_ links: [RelatedLink]) -> String {
        ([header, "> Up: [[Home]]"] + links.map { "> - [[\($0.note)]] — \($0.reason)" }).joined(separator: "\n")
    }

    /// The body with a Related block at the top (kept if there is one; new links added to it).
    public static func ensure(_ links: [RelatedLink], in body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
            var end = start + 1
            while end < lines.count, lines[end].hasPrefix(">") { end += 1 }
            let present = lines[start..<end].joined(separator: "\n")
            let missing = links.filter { !present.contains("[[\($0.note)]]") }
            lines.insert(contentsOf: missing.map { "> - [[\($0.note)]] — \($0.reason)" }, at: end)
            return lines.joined(separator: "\n")
        }
        // Directly after the frontmatter (the body starts there), followed by an empty line.
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return make(links) + "\n\n" + lines.joined(separator: "\n")
    }
}

extension NoteStore {
    /// Relative folder paths in the vault (skipping hidden and config folders).
    public func allFolders() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: vault.root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var folders: [String] = []
        for case let url as URL in enumerator {
            if Self.skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.append(relative(url)) }
        }
        return folders.sorted()
    }

    /// Notes in `Clippings/` (the inbox), flat.
    public func clippings() -> [String] {
        allNotes().filter { $0.hasPrefix("Clippings/") && $0.split(separator: "/").count == 2 }
    }

    /// Other notes containing this URL (or YouTube video id) — duplicates.
    public func notes(containing needle: String, except path: String) -> [String] {
        guard !needle.isEmpty else { return [] }
        return allNotes().filter { other in
            guard other != path, let url = try? resolve(other), let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(needle)
        }
    }

    /// A typed folder name made safe: one level, no path characters, nothing Obsidian dislikes.
    public static func topicFolderName(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "second-brain/", with: "")
            .replacingOccurrences(of: #"[\\/:*?"<>|#^\[\]]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        guard !cleaned.isEmpty, cleaned.count <= 60, cleaned != "..", !cleaned.hasPrefix(".") else { return nil }
        return cleaned
    }

    /// Creates a topic folder directly under `second-brain/` (only there; existing is fine).
    public func createTopicFolder(_ folder: String) throws {
        guard folder.hasPrefix("second-brain/"), let name = Self.topicFolderName(String(folder.dropFirst("second-brain/".count))),
            "second-brain/" + name == folder
        else { throw VaultError.invalid("New folders can only be created directly under second-brain/.") }
        let url = try resolve(folder)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw VaultError.invalid("“\(folder)” exists but isn't a folder.") }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Moves a note out of `Clippings/` into a topic folder under `second-brain/`. Never overwrites,
    /// never anywhere else — the only move the app makes in a vault.
    @discardableResult
    public func moveClipping(_ path: String, to folder: String) throws -> String {
        guard path.hasPrefix("Clippings/"), path.split(separator: "/").count == 2 else {
            throw VaultError.invalid("Only notes directly in Clippings/ are moved.")
        }
        guard folder.hasPrefix("second-brain/"), !folder.contains("..") else {
            throw VaultError.invalid("Notes are only moved into topic folders under second-brain/.")
        }
        let source = try resolve(path)
        let targetFolder = try resolve(folder)
        guard (try? targetFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw VaultError.notFound(folder)
        }
        let name = source.lastPathComponent
        let target = targetFolder.appending(path: name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw VaultError.invalid("“\(folder)/\(name)” already exists; nothing was moved.")
        }
        try FileManager.default.moveItem(at: source, to: target)
        return folder + "/" + name
    }
}
