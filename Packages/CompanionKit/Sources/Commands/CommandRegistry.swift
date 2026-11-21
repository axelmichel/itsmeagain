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
        CommandSpec(
            name: "cal", summary: "Mini calendar: click a day to see it, + to add an event", argumentHint: "[date or month]",
            kind: .native(handler: "cal"), scope: .personal, aliases: ["calendar", "month"]
        ),
        CommandSpec(
            name: "event", summary: "Add an event from a description", argumentHint: "<what> <when> [where]",
            kind: .prompt(PromptCommand(
                template: """
                    Add one calendar event for this request: $ARGUMENTS
                    Now is {{now}}. Work out the day, start time and end from the request (relative words like "tomorrow" \
                    or "Friday 3pm" are relative to now; one hour if no duration is given). Use the request's language for \
                    the title, and set the location if one is named. Call create_event, then confirm in one short sentence \
                    with weekday, date and time.
                    """,
                task: .chat,
                tools: ["calendar_events", "create_event"]
            )),
            scope: .personal,
            aliases: ["add"]
        ),
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
                    reminders that are due today or overdue, my free time today, and unread mail that needs attention \
                    (skip automated mail; [VIP] first; at most five). Mention tomorrow's first event if it starts early. \
                    Keep it short and skimmable. $ARGUMENTS
                    """,
                task: .chat,
                tools: ["calendar_events", "free_slots", "reminders", "mail_unread"]
            )),
            scope: .personal
        ),
    ]

    /// Obsidian vaults (Chat mode). Notes are only written where the user asked.
    public static let obsidian: [CommandSpec] = [
        CommandSpec(name: "note", summary: "Add a line to today's daily note", argumentHint: "<text>", kind: .native(handler: "note"), scope: .personal),
        CommandSpec(name: "capture", summary: "Save a new note in Inbox/", argumentHint: "<title> — <text>", kind: .native(handler: "capture"), scope: .personal),
        CommandSpec(name: "todos", summary: "Open tasks from your notes", argumentHint: "[due | #tag | vault]", kind: .native(handler: "todos"), scope: .personal),
        CommandSpec(name: "done", summary: "Tick off a task from your notes", argumentHint: "<words>", kind: .native(handler: "done"), scope: .personal),
        CommandSpec(name: "find", summary: "Search your notes", argumentHint: "<words>", kind: .native(handler: "find"), scope: .personal),
    ]

    /// Personal memory (Chat mode, local models only).
    public static let memory: [CommandSpec] = [
        CommandSpec(name: "remember", summary: "Remember a fact about you, a person or a preference", argumentHint: "<fact>", kind: .native(handler: "remember"), scope: .personal),
        CommandSpec(name: "forget", summary: "Find memories to forget", argumentHint: "<word>", kind: .native(handler: "forget"), scope: .personal),
        CommandSpec(name: "memories", summary: "What I know about you", argumentHint: "[kind]", kind: .native(handler: "memories"), scope: .personal),
        CommandSpec(name: "whoami", summary: "Your profile as I use it in every Chat answer", kind: .native(handler: "whoami"), scope: .personal),
    ]

    /// Apple Mail commands (personal). Mail is only read; replies become drafts the user sends.
    public static let mail: [CommandSpec] = [
        CommandSpec(name: "inbox", summary: "Unread mail of the last two days", argumentHint: "[account]", kind: .native(handler: "inbox"), scope: .personal),
        CommandSpec(
            name: "appointments", summary: "Find appointments in unread mail, check your time, add them", argumentHint: "[days]",
            kind: .native(handler: "appointments"), scope: .personal
        ),
        CommandSpec(
            name: "watched", summary: "Unread mail from your important senders, by address",
            kind: .native(handler: "watched"), scope: .personal, aliases: ["vip"]
        ),
        CommandSpec(
            name: "cleanup", summary: "Junk spam by your rules, decide on new mailing lists",
            kind: .native(handler: "cleanup"), scope: .personal, aliases: ["spam"]
        ),
        CommandSpec(
            name: "digest", summary: "Newsletter digest for your topics; digested mail is archived", argumentHint: "[days]",
            kind: .native(handler: "digest"), scope: .personal
        ),
        CommandSpec(
            name: "triage", summary: "Sort unread mail: needs reply, FYI, automated",
            kind: .prompt(PromptCommand(
                template: """
                    Triage my unread mail of the last two days (use mail_unread). Group it into: **Needs a reply**, \
                    **FYI**, and **Automated / newsletters** (one line in total for these, with a count). [VIP] senders \
                    come first. For "Needs a reply", read the message (mail_read) when the subject isn't clear enough, and \
                    state in one short line what they actually ask for, with any deadline (e.g. "wants the Q1 numbers by \
                    Monday") — not just "action needed". Don't draft replies unless I ask. $ARGUMENTS
                    """,
                task: .chat,
                tools: ["mail_unread", "mail_read"]
            )),
            scope: .personal
        ),
        CommandSpec(
            name: "from", summary: "Recent mail from someone, summarised", argumentHint: "<person>",
            kind: .prompt(PromptCommand(
                template: "Find mail from “$ARGUMENTS” of the last 30 days (mail_search with from, days 30) and summarise what they wrote, newest first. Read the latest message if needed.",
                task: .chat,
                tools: ["mail_search", "mail_read"]
            )),
            scope: .personal
        ),
        CommandSpec(
            name: "reply", summary: "Draft a reply (opens in Mail, never sent)", argumentHint: "<person or subject> — <what to say>",
            kind: .prompt(PromptCommand(
                template: """
                    Draft a reply. Request: $ARGUMENTS
                    Find the message (mail_search by sender or subject), read it (mail_read), then call \
                    mail_create_draft with reply_to_id and a reply in the language of the original. Keep it short and in my \
                    voice. The draft only opens in Mail; I send it myself.
                    """,
                task: .chat,
                tools: ["mail_search", "mail_read", "mail_create_draft"]
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
