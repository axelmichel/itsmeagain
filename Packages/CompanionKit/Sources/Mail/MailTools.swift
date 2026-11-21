import CompanionCore
import Foundation
import Tools

public enum MailToolName {
    public static let unread = "mail_unread"
    public static let search = "mail_search"
    public static let read = "mail_read"
    public static let draft = "mail_create_draft"
    public static let all = [unread, search, read, draft]
}

/// Message-IDs show up with or without angle brackets (models also drop them); try both.
enum MessageID {
    static func variants(_ id: String) -> [String] {
        let bare = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        return Array(NSOrderedSet(array: [id, bare, "<\(bare)>"])) as? [String] ?? [id]
    }

    static func lookup<T: Sendable>(_ id: String, _ attempt: (String) async throws -> T) async throws -> T {
        var lastError: Error = MailError.notFound
        for variant in variants(id) {
            do { return try await attempt(variant) } catch MailError.notFound { lastError = MailError.notFound }
        }
        throw lastError
    }
}

public enum MailFormatter {
    /// One line per message: markers, subject, sender, time, account, id.
    public static func line(_ message: MailMessage, preferences: MailPreferences, calendar: Calendar = .current, markdown: Bool = false) -> String {
        var markers: [String] = []
        switch preferences.kind(of: message) {
        case .vip: markers.append("[VIP]")
        case .newsletter: markers.append("[automated]")
        case .normal: break
        }
        if !message.isRead { markers.append("[unread]") }
        if message.isFlagged { markers.append("[flagged]") }
        let when = message.date.formatted(
            Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        )
        if markdown {
            let subject = message.subject.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
            let title = message.url.map { "[\(subject)](\($0.absoluteString))" } ?? subject
            let badges = markers.filter { $0 != "[unread]" }.joined(separator: " ")
            return "- **\(title)** — \(message.senderName) · \(when)" + (badges.isEmpty ? "" : " · \(badges)")
        }
        return ([markers.joined(separator: " ")].filter { !$0.isEmpty } + [
            "\(message.subject) — \(message.sender) · \(when) · \(message.account) (id \(message.id))",
        ]).joined(separator: " ")
    }
}

private func clamp(_ value: Int?, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
    min(max(value ?? fallback, range.lowerBound), range.upperBound)
}

public struct MailUnreadTool: Tool {
    public let source: any MailSource
    public let preferences: MailPreferences
    public init(source: any MailSource, preferences: MailPreferences) {
        self.source = source
        self.preferences = preferences
    }

    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: MailToolName.unread,
            description: """
                List recent inbox mail (sender, subject, time, account, id) — unread only by default. \
                Markers: [VIP] important sender, [automated] newsletter/notification. Bodies are not included; \
                use mail_read for one message.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "How far back (1–14, default 2)"],
                    "include_read": ["type": "boolean", "description": "Also list read mail"],
                    "account": ["type": "string", "description": "Only this account (optional)"],
                    "limit": ["type": "integer", "description": "Max messages (default 30, max 60)"],
                ],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let limit = clamp(arguments["limit"]?.intValue, 30, 1...60)
        var messages = try await source.recent(
            days: clamp(arguments["days"]?.intValue, 2, 1...14),
            unreadOnly: arguments["include_read"] != true,
            limit: limit * 2  // room for excluded accounts
        ).filter(preferences.includes)
        if let account = arguments["account"]?.stringValue {
            messages = messages.filter { $0.account.localizedCaseInsensitiveContains(account) }
        }
        messages = Array(messages.prefix(limit))
        guard !messages.isEmpty else { return ToolOutput(content: "No matching mail.") }
        let lines = messages.map { MailFormatter.line($0, preferences: preferences) }
        return ToolOutput(content: Untrusted.wrap(lines.joined(separator: "\n"), source: "mail"))
    }
}

public struct MailSearchTool: Tool {
    public let source: any MailSource
    public let preferences: MailPreferences
    public init(source: any MailSource, preferences: MailPreferences) {
        self.source = source
        self.preferences = preferences
    }

    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: MailToolName.search,
            description: "Search the inbox by words in the subject and/or the sender (name or address).",
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words in the subject"],
                    "from": ["type": "string", "description": "Sender name or address"],
                    "days": ["type": "integer", "description": "How far back (default 14, max 90)"],
                    "limit": ["type": "integer", "description": "Max messages (default 20, max 40)"],
                ],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let query = arguments["query"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let sender = arguments["from"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        guard query != nil || sender != nil else { throw ToolError.missingArgument("query or from") }
        let messages = try await source.search(
            query: query, sender: sender,
            days: clamp(arguments["days"]?.intValue, 14, 1...90),
            limit: clamp(arguments["limit"]?.intValue, 20, 1...40)
        ).filter(preferences.includes)
        guard !messages.isEmpty else { return ToolOutput(content: "No matching mail.") }
        let lines = messages.map { MailFormatter.line($0, preferences: preferences) }
        return ToolOutput(content: Untrusted.wrap(lines.joined(separator: "\n"), source: "mail"))
    }
}

public struct MailReadTool: Tool {
    public let source: any MailSource
    public let preferences: MailPreferences
    public var maxCharacters = 8_000
    public init(source: any MailSource, preferences: MailPreferences) {
        self.source = source
        self.preferences = preferences
    }

    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: MailToolName.read,
            description: "Read one message's text by id (from mail_unread or mail_search). Can take a few seconds.",
            parameters: ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let id = try arguments.requiredString("id")
        let body = try await MessageID.lookup(id) { try await source.read(id: $0) }
        guard preferences.includes(body.message) else { throw ToolError.failed("That account is excluded in Settings.") }
        var text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) + "\n[… truncated]" }
        let header = MailFormatter.line(body.message, preferences: preferences)
        let sources = body.message.url.map { [SourceRef(title: body.message.subject, url: $0.absoluteString)] } ?? []
        return ToolOutput(content: Untrusted.wrap("\(header)\n\n\(text)", source: "mail"), sources: sources)
    }
}

public struct MailDraftTool: Tool {
    public let source: any MailSource
    public init(source: any MailSource) { self.source = source }

    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { .write }

    public var spec: ToolSpec {
        ToolSpec(
            name: MailToolName.draft,
            description: """
                Open a draft in Mail for the user to review and send — never sends. For a reply pass reply_to_id \
                (to and subject then come from the original). The user approves before the draft opens.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "to": ["type": "array", "items": ["type": "string"], "description": "Recipient addresses (new mail)"],
                    "subject": ["type": "string"],
                    "body": ["type": "string"],
                    "reply_to_id": ["type": "string", "description": "Id of the message to reply to (optional)"],
                ],
                "required": ["body"],
            ]
        )
    }

    private func recipients(_ arguments: JSONValue) -> [String] {
        if case .array(let values)? = arguments["to"] { return values.compactMap(\.stringValue) }
        return arguments["to"]?.stringValue.map { [$0] } ?? []
    }

    public func describe(_ arguments: JSONValue) -> String {
        let body = (arguments["body"]?.stringValue ?? "").prefix(160)
        if arguments["reply_to_id"]?.stringValue != nil {
            return "Open a reply draft in Mail (not sent): “\(body)…”"
        }
        return "Open a draft to \(recipients(arguments).joined(separator: ", ")) — “\(arguments["subject"]?.stringValue ?? "")” (not sent)"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let body = try arguments.requiredString("body")
        let replyTo = arguments["reply_to_id"]?.stringValue
        let to = recipients(arguments)
        if replyTo == nil && to.isEmpty { throw ToolError.missingArgument("to (or reply_to_id)") }
        let subject = arguments["subject"]?.stringValue ?? ""
        let result: String
        if let replyTo {
            result = try await MessageID.lookup(replyTo) { try await source.createDraft(to: to, subject: subject, body: body, replyTo: $0) }
        } else {
            result = try await source.createDraft(to: to, subject: subject, body: body, replyTo: nil)
        }
        return ToolOutput(content: result)
    }
}

public enum MailToolbox {
    public static func tools(source: any MailSource, preferences: MailPreferences) -> [any Tool] {
        [
            MailUnreadTool(source: source, preferences: preferences),
            MailSearchTool(source: source, preferences: preferences),
            MailReadTool(source: source, preferences: preferences),
            MailDraftTool(source: source),
        ]
    }
}
