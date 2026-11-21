import Foundation

public struct MailMessage: Codable, Sendable, Hashable, Identifiable {
    /// The Message-ID header (globally unique; also used for message:// links).
    public var id: String
    public var account: String
    public var sender: String
    public var subject: String
    public var date: Date
    public var isRead: Bool
    public var isFlagged: Bool
    /// Mailing-list signals, when headers were fetched.
    public var bulk: BulkInfo?

    public init(id: String, account: String, sender: String, subject: String, date: Date, isRead: Bool, isFlagged: Bool = false, bulk: BulkInfo? = nil) {
        self.id = id
        self.account = account
        self.sender = sender
        self.subject = subject
        self.date = date
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.bulk = bulk
    }

    /// Opens the message in Mail.
    public var url: URL? {
        let raw = id.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".@-_"))) ?? raw
        return URL(string: "message://%3C\(encoded)%3E")
    }

    /// "Anna Weber <anna@x.de>" → "anna@x.de".
    public var senderAddress: String {
        if let open = sender.lastIndex(of: "<"), let close = sender.lastIndex(of: ">"), open < close {
            return String(sender[sender.index(after: open)..<close]).lowercased()
        }
        return sender.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// "Anna Weber <anna@x.de>" → "Anna Weber".
    public var senderName: String {
        guard let open = sender.lastIndex(of: "<") else { return sender }
        let name = sender[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? senderAddress : name
    }
}

public struct MailBody: Sendable, Hashable {
    public var message: MailMessage
    public var text: String
}

public enum MailError: LocalizedError, Equatable {
    case notAuthorized
    case notFound
    case timeout(String)
    case script(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "ItsMeAgain isn't allowed to control Mail. Allow it in System Settings → Privacy & Security → Automation → ItsMeAgain → Mail."
        case .notFound: "That message wasn't found in the inbox."
        case .timeout(let what): "Mail took too long (\(what)). Large or not yet downloaded messages can be slow; try again."
        case .script(let message): "Mail: \(message)"
        }
    }
}

/// Apple Mail, behind a protocol so tests use a fake.
public protocol MailSource: Sendable {
    func accounts() async throws -> [String]
    /// Inbox messages of the last `days` days, newest first.
    func recent(days: Int, unreadOnly: Bool, limit: Int) async throws -> [MailMessage]
    func search(query: String?, sender: String?, days: Int, limit: Int) async throws -> [MailMessage]
    func read(id: String) async throws -> MailBody
    /// Opens a draft window in Mail (never sends). Returns a short description.
    func createDraft(to: [String], subject: String, body: String, replyTo: String?) async throws -> String
    /// Like `recent`, with mailing-list headers parsed into `bulk`.
    func recentWithHeaders(days: Int, unreadOnly: Bool, limit: Int) async throws -> [MailMessage]
    /// Raw message sources (fast, unlike rendered content).
    func sources(ids: [String]) async throws -> [String: String]
    /// Moves messages; returns how many were found and moved.
    /// Moves messages found in `origin` (Undo moves back out of Junk or Archive).
    func move(ids: [String], to destination: MailDestination, markRead: Bool, from origin: MailDestination) async throws -> Int
    func markRead(ids: [String], _ read: Bool) async throws -> Int
}

public enum MailDestination: String, Codable, Sendable, CaseIterable {
    case junk, archive, trash, inbox
}

extension MailSource {
    public func move(ids: [String], to destination: MailDestination, markRead: Bool) async throws -> Int {
        try await move(ids: ids, to: destination, markRead: markRead, from: .inbox)
    }
}

/// Who matters and who is noise — from Settings (and later from the personal memory).
public struct MailPreferences: Sendable, Hashable {
    public var excludedAccounts: Set<String>
    /// Addresses or name fragments, lowercased.
    public var vipSenders: [String]
    public var newsletterSenders: [String]

    public init(excludedAccounts: Set<String> = [], vipSenders: [String] = [], newsletterSenders: [String] = []) {
        self.excludedAccounts = excludedAccounts
        self.vipSenders = vipSenders.map { $0.lowercased() }.filter { !$0.isEmpty }
        self.newsletterSenders = newsletterSenders.map { $0.lowercased() }.filter { !$0.isEmpty }
    }

    public enum Kind: String, Sendable { case vip, newsletter, normal }

    /// Deterministic pre-classification; the model refines the rest.
    public func kind(of message: MailMessage) -> Kind {
        let sender = message.sender.lowercased()
        if vipSenders.contains(where: { sender.contains($0) }) { return .vip }
        if newsletterSenders.contains(where: { sender.contains($0) }) { return .newsletter }
        let automated = ["noreply", "no-reply", "donotreply", "do-not-reply", "newsletter", "news@", "notifications@", "notification@", "marketing", "mailer-daemon", "info@"]
        return automated.contains(where: { message.senderAddress.contains($0) }) ? .newsletter : .normal
    }

    public func includes(_ message: MailMessage) -> Bool {
        !excludedAccounts.contains(message.account)
    }
}
