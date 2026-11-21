import Foundation

/// Where the app keeps its data, and the one-time move out of the App Sandbox container.
enum AppData {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.axelmichel.itsmeagain"

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "ItsMeAgain", directoryHint: .isDirectory)
    }

    static var store: URL { directory.appending(path: "ItsMeAgain.store") }
    static var knowledge: URL { directory.appending(path: "Knowledge", directoryHint: .isDirectory) }
    /// The personal memory, readable JSON.
    static var memory: URL { directory.appending(path: "Memory.json") }
    /// News feeds and the last 30 days of items.
    static var news: URL { directory.appending(path: "News.json") }
    /// Vocabulary cards with their review schedule.
    static var flashcards: URL { directory.appending(path: "Flashcards.json") }
    /// Empty working directory for Claude Code, so no project settings or CLAUDE.md apply.
    static var claudeCodeWorkdir: URL { directory.appending(path: "ClaudeCode", directoryHint: .isDirectory) }

    /// Builds before the sandbox was turned off stored everything in the container. Copy (never move) the
    /// conversations database and the settings over once, so the old data stays as a backup.
    static func migrateFromSandboxContainer(defaults: UserDefaults = .standard) {
        let fileManager = FileManager.default
        let container = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/\(bundleID)/Data/Library", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let oldStore = container.appending(path: "Application Support/default.store")
        if !fileManager.fileExists(atPath: store.path(percentEncoded: false)),
            fileManager.fileExists(atPath: oldStore.path(percentEncoded: false))
        {
            // SQLite finds its WAL/SHM files by name, so they are renamed along with the database.
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(filePath: oldStore.path(percentEncoded: false) + suffix)
                let target = URL(filePath: store.path(percentEncoded: false) + suffix)
                if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                    try? fileManager.copyItem(at: source, to: target)
                }
            }
        }

        let oldKnowledge = container.appending(path: "Application Support/Knowledge")
        if !fileManager.fileExists(atPath: knowledge.path(percentEncoded: false)),
            fileManager.fileExists(atPath: oldKnowledge.path(percentEncoded: false))
        {
            try? fileManager.copyItem(at: oldKnowledge, to: knowledge)
        }

        let migratedKey = "migratedFromSandboxContainer"
        let oldPreferences = container.appending(path: "Preferences/\(bundleID).plist")
        if !defaults.bool(forKey: migratedKey),
            let values = NSDictionary(contentsOf: oldPreferences) as? [String: Any]
        {
            for (key, value) in values where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migratedKey)
    }
}
