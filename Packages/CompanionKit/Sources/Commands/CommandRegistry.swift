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

    /// Calendar and reminder commands (personal: they always run in Chat).
    public static let calendar: [CommandSpec] = [
        CommandSpec(name: "today", summary: "Today's events and due reminders", kind: .native(handler: "today"), scope: .personal),
        CommandSpec(name: "tomorrow", summary: "Tomorrow's events", kind: .native(handler: "tomorrow"), scope: .personal),
        CommandSpec(name: "week", summary: "Events for the next seven days", kind: .native(handler: "week"), scope: .personal),
        CommandSpec(name: "agenda", summary: "Events on a given day", argumentHint: "<date>", kind: .native(handler: "agenda"), scope: .personal),
        CommandSpec(name: "free", summary: "Free time in your calendar", argumentHint: "<30m|1h> [day]", kind: .native(handler: "free"), scope: .personal),
        CommandSpec(name: "reminders", summary: "Open reminders, overdue first", argumentHint: "[list]", kind: .native(handler: "reminders"), scope: .personal),
        CommandSpec(
            name: "remind", summary: "Create a reminder", argumentHint: "<what> [when]",
            kind: .prompt(PromptCommand(
                template: """
                    Create one reminder for this request: $ARGUMENTS
                    Now is {{now}}. Work out the due day and time from the request (relative words like "tomorrow" or \
                    "Friday 6pm" are relative to now). If no time is given, set only the day; if no day is given, set no \
                    due date. Use the request's language for the title. Then confirm in one short sentence.
                    """,
                task: .chat,
                tools: ["create_reminder"]
            )),
            scope: .personal
        ),
        CommandSpec(
            name: "brief", summary: "Your brief for today: calendar, reminders, free time",
            kind: .prompt(PromptCommand(
                template: """
                    Give me my brief for {{today}} ({{date}}): today's events with times, anything I should prepare for, \
                    reminders that are due today or overdue, and my free time today. Mention tomorrow's first event if \
                    it starts early. Keep it short and skimmable. $ARGUMENTS
                    """,
                task: .chat,
                tools: ["calendar_events", "free_slots", "reminders"]
            )),
            scope: .personal
        ),
    ]

    /// The commands every installation has; the app implements the native handlers.
    public static let general: [CommandSpec] = [
        CommandSpec(name: "help", summary: "List all commands", kind: .native(handler: "help"), scope: .general),
        CommandSpec(name: "new", summary: "Start a new conversation", argumentHint: "[chat|translate|research|code]", kind: .native(handler: "new"), scope: .general),
        CommandSpec(name: "task", summary: "Switch this conversation's mode", argumentHint: "<chat|translate|research|code>", kind: .native(handler: "task"), scope: .general),
        CommandSpec(name: "auto", summary: "Route each message to the right mode automatically", kind: .native(handler: "auto"), scope: .general),
    ]
}
