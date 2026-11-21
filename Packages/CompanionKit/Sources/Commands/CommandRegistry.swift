import Foundation

/// Built-in and user commands, resolved by name or alias.
public struct CommandRegistry: Sendable {
    public private(set) var commands: [CommandSpec]
    /// User commands that were skipped, with the reason.
    public private(set) var conflicts: [String]

    public init(builtIns: [CommandSpec], user: [CommandSpec] = []) {
        var byName: [String: CommandSpec] = [:]
        var conflicts: [String] = []
        for command in builtIns { byName[command.name] = command }
        for command in user {
            if let existing = byName[command.name] {
                if case .builtIn = existing.source, command.overridesBuiltIn {
                    byName[command.name] = command
                } else {
                    conflicts.append("/\(command.name) already exists; add “override: true” to replace the built-in.")
                }
            } else {
                byName[command.name] = command
            }
        }
        commands = byName.values.sorted { $0.name < $1.name }
        self.conflicts = conflicts
    }

    public func command(named name: String) -> CommandSpec? {
        let name = name.lowercased()
        return commands.first { $0.name == name } ?? commands.first { $0.aliases.contains(name) }
    }

    /// Suggestions while typing the name: "/to" → `/today`, `/todos`, …; prefix matches first.
    public func completions(for text: String) -> [CommandSpec] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let partial = text.dropFirst().lowercased()
        guard !partial.isEmpty else { return commands }
        let prefix = commands.filter { $0.name.hasPrefix(partial) || $0.aliases.contains { $0.hasPrefix(partial) } }
        let contains = commands.filter { $0.name.contains(partial) && !prefix.contains($0) }
        return prefix + contains
    }

    /// The commands every installation has; the app implements the native handlers.
    public static let general: [CommandSpec] = [
        CommandSpec(name: "help", summary: "List all commands", kind: .native(handler: "help"), scope: .general),
        CommandSpec(name: "new", summary: "Start a new conversation", argumentHint: "[chat|translate|research|code]", kind: .native(handler: "new"), scope: .general),
        CommandSpec(name: "task", summary: "Switch this conversation's mode", argumentHint: "<chat|translate|research|code>", kind: .native(handler: "task"), scope: .general),
        CommandSpec(name: "auto", summary: "Route each message to the right mode automatically", kind: .native(handler: "auto"), scope: .general),
    ]
}
