import CompanionCore
import Foundation
import Tools

public enum ObsidianToolName {
    public static let searchNotes = "search_notes"
    public static let readNote = "read_note"
    public static let listTasks = "list_tasks"
    public static let appendDailyNote = "append_daily_note"
    public static let createNote = "create_note"
    public static let completeTask = "complete_task"
}

/// A note found by meaning (embedding search over the vault index).
public struct SemanticNoteHit: Sendable, Hashable {
    public var vault: String
    public var path: String
    public var snippet: String
    public var score: Float

    public init(vault: String, path: String, snippet: String, score: Float) {
        self.vault = vault
        self.path = path
        self.snippet = snippet
        self.score = score
    }
}

/// The vaults the assistant may use; the first is the main one (daily note, captures).
public struct VaultSet: Sendable {
    public typealias SemanticSearch = @Sendable (_ query: String, _ vaults: [String]) async -> [SemanticNoteHit]

    public let stores: [NoteStore]
    /// Search by meaning, when the vaults are indexed; word search otherwise.
    public let semantic: SemanticSearch?

    public init(stores: [NoteStore], semantic: SemanticSearch? = nil) {
        self.stores = stores
        self.semantic = semantic
    }

    /// Meaning first (when indexed), then word matches; one entry per note, best first.
    public func search(_ query: String, in stores: [NoteStore], limit: Int = 10) async -> [SemanticNoteHit] {
        var hits: [SemanticNoteHit] = []
        if let semantic {
            hits = await semantic(query, stores.map(\.vault.name)).filter { $0.score >= 0.35 }
        }
        for store in stores {
            for hit in store.search(query, limit: limit) {
                hits.append(SemanticNoteHit(vault: store.vault.name, path: hit.path, snippet: hit.snippet, score: 0.3 + Float(min(hit.score, 20)) / 100))
            }
        }
        var seen = Set<String>()
        return Array(hits.sorted { $0.score > $1.score }.filter { seen.insert($0.vault + "/" + $0.path).inserted }.prefix(limit))
    }

    /// "@cooking rest of text" → (cooking store, "rest of text"); otherwise (nil, text).
    public func splitVaultPrefix(_ text: String) -> (store: NoteStore?, rest: String) {
        guard text.hasPrefix("@") else { return (nil, text) }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        guard let store = stores.first(where: { $0.vault.name.localizedCaseInsensitiveCompare(String(name)) == .orderedSame }) else { return (nil, text) }
        return (store, String(text.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces))
    }

    public var main: NoteStore? { stores.first }

    public func store(named name: String?) throws -> NoteStore {
        guard let name, !name.isEmpty else {
            guard let main else { throw VaultError.invalid("No Obsidian vault is enabled (Settings → Assistant → Obsidian).") }
            return main
        }
        guard let store = stores.first(where: { $0.vault.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw VaultError.invalid("No enabled vault named “\(name)”. Enabled: \(stores.map(\.vault.name).joined(separator: ", ")).")
        }
        return store
    }

    var vaultParameter: JSONValue {
        let description = "Vault name (optional; default \(main?.vault.name ?? "the main vault")). Vaults: \(stores.map(\.vault.name).joined(separator: ", "))"
        return ["type": "string", "description": .string(description)]
    }
}

public enum ObsidianToolbox {
    public static func tools(_ vaults: VaultSet) -> [any Tool] {
        guard !vaults.stores.isEmpty else { return [] }
        return [SearchNotesTool(vaults: vaults), ReadNoteTool(vaults: vaults), ListTasksTool(vaults: vaults),
                AppendDailyNoteTool(vaults: vaults), CreateNoteTool(vaults: vaults), CompleteTaskTool(vaults: vaults)]
    }
}

public struct SearchNotesTool: Tool {
    let vaults: VaultSet
    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: ObsidianToolName.searchNotes,
            description: "Search the user's Obsidian notes by meaning and words. Returns note paths with a matching passage.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string"], "vault": vaults.vaultParameter],
                "required": ["query"],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let query = try arguments.requiredString("query")
        let stores = try arguments["vault"]?.stringValue.map { [try vaults.store(named: $0)] } ?? vaults.stores
        var lines: [String] = []
        var sources: [SourceRef] = []
        for hit in await vaults.search(query, in: stores) {
            lines.append("- [\(hit.vault)] \(hit.path): \(hit.snippet)")
            if let url = stores.first(where: { $0.vault.name == hit.vault })?.vault.url(for: hit.path) {
                sources.append(SourceRef(title: hit.path, url: url.absoluteString))
            }
        }
        guard !lines.isEmpty else { return ToolOutput(content: "No notes match “\(query)”.") }
        return ToolOutput(content: Untrusted.wrap(lines.joined(separator: "\n"), source: "notes"), sources: sources)
    }
}

public struct ReadNoteTool: Tool {
    let vaults: VaultSet
    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: ObsidianToolName.readNote,
            description: "Read one Obsidian note by path or name (from search_notes).",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"], "vault": vaults.vaultParameter],
                "required": ["path"],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let store = try vaults.store(named: arguments["vault"]?.stringValue)
        let note = try store.read(try arguments.requiredString("path"))
        var text = (note.frontmatter.map { "---\n\($0)\n---\n" } ?? "") + note.body
        if text.count > 10_000 { text = String(text.prefix(10_000)) + "\n[… truncated]" }
        let sources = store.vault.url(for: note.path).map { [SourceRef(title: note.title, url: $0.absoluteString)] } ?? []
        // Notes can hold clipped web pages: their text is data, not instructions.
        return ToolOutput(content: "Note \(note.path) (modified \(note.modified.formatted())):\n" + Untrusted.wrap(text, source: "note"), sources: sources)
    }
}

public struct ListTasksTool: Tool {
    let vaults: VaultSet
    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: ObsidianToolName.listTasks,
            description: "Open tasks (checkboxes) in the user's Obsidian notes, with due dates and tags.",
            parameters: [
                "type": "object",
                "properties": [
                    "filter": ["type": "string", "enum": ["all", "due", "tag"], "description": "due = overdue or due today; tag needs `tag`"],
                    "tag": ["type": "string"],
                    "vault": vaults.vaultParameter,
                ],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let stores = try arguments["vault"]?.stringValue.map { [try vaults.store(named: $0)] } ?? vaults.stores
        var tasks = stores.flatMap { $0.tasks() }
        switch arguments["filter"]?.stringValue {
        case "due": tasks = tasks.filter { $0.isDue() }
        case "tag":
            let tag = (arguments["tag"]?.stringValue ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
            tasks = tasks.filter { $0.tags.contains { $0.lowercased() == tag } }
        default: break
        }
        guard !tasks.isEmpty else { return ToolOutput(content: "No open tasks.") }
        let lines = tasks.prefix(60).map { VaultTaskFormatter.line($0) + " (id \($0.id))" }
        return ToolOutput(content: Untrusted.wrap(lines.joined(separator: "\n"), source: "notes"))
    }
}

public struct AppendDailyNoteTool: Tool {
    let vaults: VaultSet
    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { .write }

    public var spec: ToolSpec {
        ToolSpec(
            name: ObsidianToolName.appendDailyNote,
            description: "Add a line to today's daily note in the main vault (created if missing). The user approves first.",
            parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
        )
    }

    public func describe(_ arguments: JSONValue) -> String {
        "Add to today's daily note: “\(arguments["text"]?.stringValue ?? "")”"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let store = try vaults.store(named: nil)
        let path = try store.appendToDailyNote(try arguments.requiredString("text"))
        return ToolOutput(content: "Added to \(path).")
    }
}

public struct CreateNoteTool: Tool {
    let vaults: VaultSet
    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { .write }

    public var spec: ToolSpec {
        ToolSpec(
            name: ObsidianToolName.createNote,
            description: "Create a new note (never overwrites). Default folder: Inbox. The user approves first.",
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string"], "text": ["type": "string"],
                    "folder": ["type": "string", "description": "Folder in the vault (default Inbox)"],
                    "vault": vaults.vaultParameter,
                ],
                "required": ["title", "text"],
            ]
        )
    }

    public func describe(_ arguments: JSONValue) -> String {
        let folder = arguments["folder"]?.stringValue ?? "Inbox"
        return "Create note “\(arguments["title"]?.stringValue ?? "")” in \(folder)/"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let store = try vaults.store(named: arguments["vault"]?.stringValue)
        let path = try store.createNote(
            title: try arguments.requiredString("title"), text: try arguments.requiredString("text"),
            folder: arguments["folder"]?.stringValue ?? "Inbox"
        )
        return ToolOutput(content: "Created \(path) in \(store.vault.name).")
    }
}

public struct CompleteTaskTool: Tool {
    let vaults: VaultSet
    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { .write }

    public var spec: ToolSpec {
        ToolSpec(
            name: ObsidianToolName.completeTask,
            description: "Tick off an open task by its id (from list_tasks). The user approves first.",
            parameters: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]
        )
    }

    func find(_ id: String) throws -> (NoteStore, VaultTask) {
        for store in vaults.stores {
            if let task = store.tasks().first(where: { $0.id == id }) { return (store, task) }
        }
        throw VaultError.notFound(id)
    }

    public func describe(_ arguments: JSONValue) -> String {
        let id = arguments["id"]?.stringValue ?? ""
        let text = (try? find(id).1.text) ?? id
        return "Tick off “\(text)”"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let (store, task) = try find(try arguments.requiredString("id"))
        try store.setDone(task, true)
        return ToolOutput(content: "Done: \(task.text)")
    }
}

public enum VaultTaskFormatter {
    public static func line(_ task: VaultTask, calendar: Calendar = .current) -> String {
        var parts = ["[\(task.isDone ? "x" : " ")] \(task.text)"]
        if let due = task.due { parts.append("due \(day(due, calendar: calendar))") }
        if let scheduled = task.scheduled { parts.append("scheduled \(day(scheduled, calendar: calendar))") }
        if task.priority > 0 { parts.append(String(repeating: "!", count: task.priority)) }
        parts.append("in \(task.path)")
        return parts.joined(separator: " · ")
    }

    public static func day(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        if date < calendar.startOfDay(for: .now) { return "overdue (\(date.formatted(.dateTime.day().month(.abbreviated))))" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
