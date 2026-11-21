import Foundation
import Routing

/// A slash command: built in (native handler or prompt) or defined by the user as a Markdown file.
public struct CommandSpec: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Handled in Swift by the app (`handler` identifies which).
        case native(handler: String)
        case prompt(PromptCommand)
    }

    /// Personal commands touch the user's own data and always run in Chat mode.
    public enum Scope: String, Sendable, Hashable {
        case general, personal
    }

    public enum Source: Sendable, Hashable {
        case builtIn
        case user(path: String)
    }

    public var name: String
    public var summary: String
    /// Shown after the name while typing, e.g. "<text> [when]".
    public var argumentHint: String?
    public var kind: Kind
    public var scope: Scope
    public var source: Source
    public var aliases: [String]
    /// A user command may replace a built-in of the same name only if it says so.
    public var overridesBuiltIn: Bool

    public var id: String { name }

    public init(
        name: String,
        summary: String,
        argumentHint: String? = nil,
        kind: Kind,
        scope: Scope,
        source: Source = .builtIn,
        aliases: [String] = [],
        overridesBuiltIn: Bool = false
    ) {
        self.name = name
        self.summary = summary
        self.argumentHint = argumentHint
        self.kind = kind
        self.scope = scope
        self.source = source
        self.aliases = aliases
        self.overridesBuiltIn = overridesBuiltIn
    }
}

/// A command that expands into a prompt for the model.
public struct PromptCommand: Sendable, Hashable {
    /// Placeholders: `$ARGUMENTS`, `$1`…`$9`, `{{today}}`, `{{now}}`, `{{date}}`, `{{date:+1d}}`.
    public var template: String
    public var task: TaskKind
    /// Tool names the command may use; `nil` means the task's tools.
    public var tools: [String]?
    /// Write tools that run without asking during this command.
    public var autoApproved: Set<String>

    public init(template: String, task: TaskKind = .chat, tools: [String]? = nil, autoApproved: Set<String> = []) {
        self.template = template
        self.task = task
        self.tools = tools
        self.autoApproved = autoApproved
    }
}

/// What the user typed: `/name rest of the line`.
public struct CommandInput: Sendable, Hashable {
    public var name: String
    /// Everything after the name, trimmed (`$ARGUMENTS`).
    public var arguments: String
    /// Whitespace-separated arguments; "double" or 'single' quotes group words (`$1`…).
    public var positional: [String]

    /// Nil unless the text starts with `/` followed by a name.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        self.name = name.lowercased()
        arguments = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        positional = Self.split(arguments)
    }

    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken { parts.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { parts.append(current) }
        return parts
    }
}
