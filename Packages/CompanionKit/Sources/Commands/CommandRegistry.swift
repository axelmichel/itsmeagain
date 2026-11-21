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
        CommandSpec(name: "weather", summary: "Weather now and the next hours", kind: .native(handler: "weather"), scope: .general),
        CommandSpec(name: "free", summary: "Free time in your calendar", argumentHint: "<30m|1h> [day]", kind: .native(handler: "free"), scope: .personal),
        CommandSpec(
            name: "planday", summary: "Plan the day: a list of tasks → reminders to tick off", argumentHint: "one task per line (14:00 … sets a time)",
            kind: .native(handler: "planday"), scope: .personal, aliases: ["plan"]
        ),
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
                    End with the three most relevant news items for my interests (news, one line each with the link). \
                    Keep it short and skimmable. $ARGUMENTS
                    """,
                task: .chat,
                tools: ["calendar_events", "free_slots", "reminders", "mail_unread", "news"]
            )),
            scope: .personal
        ),
    ]

    /// Jira (read-only, several sites).
    public static let jira: [CommandSpec] = [
        CommandSpec(name: "jira", summary: "A ticket (or search your Jira sites)", argumentHint: "<KEY-123 … | words>", kind: .native(handler: "jira"), scope: .personal),
        CommandSpec(name: "myjira", summary: "Your open Jira tickets across all sites", argumentHint: "[site]", kind: .native(handler: "myjira"), scope: .personal),
    ]

    /// News from the user's feeds (public data, but it runs in Chat with the other personal commands).
    public static let news: [CommandSpec] = [
        CommandSpec(name: "news", summary: "Today's news for your interests", argumentHint: "[topic]", kind: .native(handler: "news"), scope: .personal),
    ]

    /// Obsidian vaults (Chat mode). Notes are only written where the user asked.
    public static let obsidian: [CommandSpec] = [
        CommandSpec(name: "note", summary: "Add a line to today's daily note", argumentHint: "[@vault] <text>", kind: .native(handler: "note"), scope: .personal),
        CommandSpec(name: "capture", summary: "Save a new note in Inbox/", argumentHint: "[@vault] <title> — <text>", kind: .native(handler: "capture"), scope: .personal),
        CommandSpec(name: "todos", summary: "Open tasks from your notes", argumentHint: "[due | #tag | vault]", kind: .native(handler: "todos"), scope: .personal),
        CommandSpec(name: "done", summary: "Tick off a task from your notes", argumentHint: "<words>", kind: .native(handler: "done"), scope: .personal),
        CommandSpec(name: "find", summary: "Search your notes by meaning and words", argumentHint: "[@vault] <words>", kind: .native(handler: "find"), scope: .personal),
        CommandSpec(name: "yt-playlist", summary: "Your YouTube playlist: pick videos to turn into notes", kind: .native(handler: "yt-playlist"), scope: .personal),
        CommandSpec(name: "yt", summary: "Notes from YouTube videos (then sorting)", argumentHint: "<url> [url …]", kind: .native(handler: "yt"), scope: .personal),
        CommandSpec(name: "yt-next", summary: "The oldest new playlist video as a note (for an hourly automation)", argumentHint: "[count]", kind: .native(handler: "yt-next"), scope: .personal),
        CommandSpec(name: "einordnen", summary: "Sort notes from Clippings/ into topic folders (you confirm)", kind: .native(handler: "einordnen"), scope: .personal, aliases: ["sort"]),
        CommandSpec(name: "dayplan", summary: "Today's events into the daily note (Day Planner)", kind: .native(handler: "dayplan"), scope: .personal),
    ]

    /// Languages: checking your text, vocabulary cards, learning them.
    public static let learning: [CommandSpec] = [
        CommandSpec(name: "spelling", summary: "Check a text you wrote: errors highlighted, corrected version", argumentHint: "<text>", kind: .native(handler: "spelling"), scope: .general, aliases: ["check"]),
        CommandSpec(name: "flashcard", summary: "Make a vocabulary card and keep it", argumentHint: "<word> [language]", kind: .native(handler: "flashcard"), scope: .general, aliases: ["card"]),
        CommandSpec(name: "learn", summary: "Learn your cards (due first, then new)", argumentHint: "[number] [language]", kind: .native(handler: "learn"), scope: .general),
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
            name: "appointments", summary: "Find appointments in last week's mail, check your time, add them", argumentHint: "[days, max 7]",
            kind: .native(handler: "appointments"), scope: .personal
        ),
        CommandSpec(
            name: "important", summary: "Add a sender to your important senders (notify on new mail)", argumentHint: "<address | @domain | name>",
            kind: .native(handler: "important"), scope: .personal
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
            name: "triage", summary: "Unread mail sorted, with Read / Archive / Delete / Reply / Rule", argumentHint: "[days]",
            kind: .native(handler: "triage"), scope: .personal
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
