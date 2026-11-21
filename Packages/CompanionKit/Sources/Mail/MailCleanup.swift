import Foundation

/// Mailing-list signals from headers.
public struct BulkInfo: Codable, Sendable, Hashable {
    public var isBulk: Bool
    public var listID: String?
    /// https unsubscribe link from List-Unsubscribe.
    public var unsubscribeURL: String?
    /// RFC 8058: the link accepts a one-click POST.
    public var oneClick: Bool
    public var unsubscribeMailto: String?

    public init(isBulk: Bool = false, listID: String? = nil, unsubscribeURL: String? = nil, oneClick: Bool = false, unsubscribeMailto: String? = nil) {
        self.isBulk = isBulk
        self.listID = listID
        self.unsubscribeURL = unsubscribeURL
        self.oneClick = oneClick
        self.unsubscribeMailto = unsubscribeMailto
    }

    public var canUnsubscribe: Bool { unsubscribeURL != nil || unsubscribeMailto != nil }

    public static func from(headers: [String: String]) -> BulkInfo {
        var info = BulkInfo()
        if let list = headers["list-unsubscribe"] {
            for entry in list.split(separator: ",") {
                let value = entry.trimmingCharacters(in: CharacterSet(charactersIn: " <>"))
                if value.lowercased().hasPrefix("https://"), info.unsubscribeURL == nil { info.unsubscribeURL = value }
                if value.lowercased().hasPrefix("mailto:"), info.unsubscribeMailto == nil { info.unsubscribeMailto = String(value.dropFirst(7)) }
            }
            info.isBulk = true
        }
        info.oneClick = (headers["list-unsubscribe-post"] ?? "").localizedCaseInsensitiveContains("one-click") && info.unsubscribeURL != nil
        if let id = headers["list-id"] {
            info.listID = id
            info.isBulk = true
        }
        if let precedence = headers["precedence"]?.lowercased(), ["bulk", "list", "junk"].contains(precedence) { info.isBulk = true }
        if let auto = headers["auto-submitted"]?.lowercased(), auto != "no" { info.isBulk = true }
        return info
    }
}

public enum SenderAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// On the watch list: a notification for new mail, always at the top.
    case important
    /// Leave it alone (personal or wanted as-is).
    case keep
    /// Newsletter worth reading: goes into the digest, then read + archived.
    case digest
    /// Stays in the inbox, marked as read.
    case markRead
    /// Archived right away.
    case archive
    /// Moved to the trash.
    case trash
    /// Unwanted: moved to Junk.
    case junk

    public var title: String {
        switch self {
        case .important: "Important"
        case .keep: "Keep"
        case .digest: "Digest"
        case .markRead: "Mark as read"
        case .archive: "Archive"
        case .trash: "Delete"
        case .junk: "Junk"
        }
    }

    /// What the rule does to a message, for the menus ("From now on, mail from Tom: …").
    public var explanation: String {
        switch self {
        case .important: "is important — notify me"
        case .keep: "stays as it is"
        case .digest: "goes into the newsletter digest"
        case .markRead: "is marked as read"
        case .archive: "is archived"
        case .trash: "is deleted (to the trash)"
        case .junk: "goes to Junk"
        }
    }

    /// Rules that change mail on their own (applied by /cleanup, /triage and the mail watch).
    public var isAutomatic: Bool { [.markRead, .archive, .trash, .junk].contains(self) }

    /// Order, invoice and account mail is never handled by these (it stays visible).
    var sparesTransactionalMail: Bool { ![.important, .keep].contains(self) }

    /// Mail from such senders is filed under "Automated" in /triage.
    public var isAutomatedMail: Bool { [.digest, .markRead, .archive, .trash, .junk].contains(self) }
}

/// One learned decision per sender address or whole domain ("@news.example.com").
public struct SenderRule: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var action: SenderAction
    /// Display name of the sender when the rule was made; also shown to the model as an example.
    public var name: String?
    public var createdAt: Date

    public var id: String { key }

    public init(key: String, action: SenderAction, name: String? = nil, createdAt: Date = .now) {
        self.key = key.lowercased()
        self.action = action
        self.name = name
        self.createdAt = createdAt
    }
}

public struct SenderRuleBook: Codable, Sendable, Hashable {
    public private(set) var rules: [SenderRule]
    /// Learned in /triage: which group a sender's mail belongs to (address → category raw value).
    public private(set) var categories: [String: String]

    public init(rules: [SenderRule] = [], categories: [String: String] = [:]) {
        self.rules = rules
        self.categories = categories
    }

    enum CodingKeys: String, CodingKey { case rules, categories }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decodeIfPresent([SenderRule].self, forKey: .rules) ?? []
        categories = try container.decodeIfPresent([String: String].self, forKey: .categories) ?? [:]
    }

    public func category(for address: String) -> String? {
        categories[address.lowercased()]
    }

    public mutating func setCategory(_ category: String?, for address: String) {
        categories[address.lowercased()] = category
    }

    /// Exact address first, then the domain rule.
    public func action(for address: String) -> SenderAction? {
        let address = address.lowercased()
        if let exact = rules.first(where: { $0.key == address }) { return exact.action }
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = String(address[at...])
        return rules.first { $0.key == domain }?.action
    }

    /// The rule for one message, with two limits so rules stay narrow: a domain rule only covers
    /// mailing-list mail, and order / invoice / shipping / account mail is never junked or digested,
    /// even by an address rule (shops often send those from the same domain as their ads).
    public func action(for message: MailMessage) -> SenderAction? {
        rule(for: message)?.action
    }

    /// The rule that applies to a message (address rule first, then the domain's).
    public func rule(for message: MailMessage) -> SenderRule? {
        let address = message.senderAddress.lowercased()
        if let exact = rules.first(where: { $0.key == address }) {
            if exact.action.sparesTransactionalMail, TransactionalMail.subjectMatches(message.subject) { return nil }
            return exact
        }
        guard let at = address.lastIndex(of: "@"), let rule = rules.first(where: { $0.key == String(address[at...]) }) else { return nil }
        if !rule.action.sparesTransactionalMail { return rule }
        guard message.bulk?.isBulk == true, !TransactionalMail.looksTransactional(message) else { return nil }
        return rule
    }

    /// A rule exists for the sender, but this message is protected from it.
    public func protects(_ message: MailMessage) -> Bool {
        action(for: message.senderAddress) != nil && action(for: message) == nil
    }

    public mutating func set(_ key: String, _ action: SenderAction, name: String? = nil) {
        rules.removeAll { $0.key == key.lowercased() }
        rules.append(SenderRule(key: key, action: action, name: name))
        rules.sort { $0.key < $1.key }
    }

    public mutating func remove(_ key: String) {
        rules.removeAll { $0.key == key.lowercased() }
    }
}

/// Mailing-list mail of one sender, for the cleanup view.
public struct SenderGroup: Codable, Sendable, Hashable, Identifiable {
    public var address: String
    public var name: String
    public var messages: [MailMessage]
    public var bulk: BulkInfo
    /// The learned rule, if any.
    public var rule: SenderAction?
    /// The model's suggestion for senders without a rule.
    public var suggestion: SenderAction?
    public var reason: String?
    /// What happened in the cleanup view ("Moved 3 to Junk").
    public var outcome: String?
    /// Where the messages were moved, for Undo.
    public var movedTo: MailDestination?

    public var id: String { address }
}

public enum MailTriage {
    /// Groups mailing-list mail (and anything with a rule) by sender, largest groups first.
    /// Mail a rule doesn't cover because it looks like an order, invoice or account mail stays out:
    /// it is left alone in the inbox.
    public static func groups(_ messages: [MailMessage], rules: SenderRuleBook) -> [SenderGroup] {
        let relevant = messages.filter { !rules.protects($0) && (($0.bulk?.isBulk ?? false) || rules.action(for: $0) != nil) }
        let bySender = Dictionary(grouping: relevant, by: \.senderAddress)
        return bySender.map { address, items in
            let sorted = items.sorted { $0.date > $1.date }
            return SenderGroup(
                address: address,
                name: sorted[0].senderName,
                messages: sorted,
                bulk: sorted.compactMap(\.bulk).first(where: \.canUnsubscribe) ?? sorted[0].bulk ?? BulkInfo(),
                rule: sorted.lazy.compactMap { rules.action(for: $0) }.first
            )
        }
        .sorted { ($0.messages.count, $1.address) > ($1.messages.count, $0.address) }
    }
}

public struct CleanupResult: Sendable {
    /// Senders still to decide (with suggestions), then senders handled by a rule this run.
    public var groups: [SenderGroup]
    public var junked: Int
    public var waitingForDigest: Int
    /// Order, invoice and account mail from ruled senders, left in the inbox.
    public var protected: Int = 0
}

public enum MailCleanup {
    /// Applies the learned junk rules (moves to Junk, marks read) and returns the senders still to
    /// decide, with the model's suggestions when a model is given. Mail is only ever moved by a rule
    /// the user made, never by a suggestion.
    public static func run(
        source: any MailSource,
        rules: SenderRuleBook,
        preferences: MailPreferences = MailPreferences(),
        topics: [String],
        model: MailModel?,
        days: Int = 7,
        limit: Int = 120
    ) async throws -> CleanupResult {
        let messages = try await source.recentWithHeaders(days: days, unreadOnly: false, limit: limit)
            .filter { preferences.includes($0) && preferences.kind(of: $0) != .vip }
        var groups = MailTriage.groups(messages, rules: rules)
        let protected = messages.filter(rules.protects).count

        var junked = 0
        for index in groups.indices where groups[index].rule?.isAutomatic == true {
            let summary = try await RuleApplier.apply(groups[index].messages, rules: rules, source: source)
            junked += summary.junked
            guard summary.total > 0 else { continue }
            groups[index].outcome = summary.text.prefix(1).uppercased() + summary.text.dropFirst() + " (your rule)"
            groups[index].movedTo = summary.junked > 0 ? .junk : summary.deleted > 0 ? .trash : summary.archived > 0 ? .archive : nil
        }
        let waiting = groups.filter { $0.rule == .digest }.reduce(0) { $0 + $1.messages.filter { !$0.isRead }.count }

        let undecided = groups.indices.filter { groups[$0].rule == nil }
        if let model, !undecided.isEmpty,
            let suggestions = try? await SenderAdvisor.suggest(undecided.map { groups[$0] }, topics: topics, rules: rules, model: model)
        {
            for index in undecided {
                guard let suggestion = suggestions[groups[index].address] else { continue }
                groups[index].suggestion = suggestion.action
                groups[index].reason = suggestion.reason
            }
        }
        // Senders your rules already handled don't show up again; the summary line says what happened.
        let shown = groups.filter { $0.rule == nil }
        return CleanupResult(groups: shown, junked: junked, waitingForDigest: waiting, protected: protected)
    }

    public static func summary(_ result: CleanupResult) -> String {
        var parts: [String] = []
        if result.junked > 0 { parts.append("Moved **\(result.junked)** to Junk by your rules.") }
        let open = result.groups.filter { $0.rule == nil }
        if open.isEmpty {
            parts.append(result.junked == 0 ? "Nothing to clean up." : "No new senders to decide.")
        } else {
            parts.append("**\(open.count) \(open.count == 1 ? "sender" : "senders")** to decide. Your choice becomes a rule that runs automatically from now on.")
        }
        if result.protected > 0 {
            parts.append(result.protected == 1
                ? "Left 1 order or account mail from a ruled sender in your inbox."
                : "Left \(result.protected) order or account mails from ruled senders in your inbox.")
        }
        if result.waitingForDigest > 0 {
            let count = result.waitingForDigest
            parts.append(count == 1 ? "1 newsletter waits for /digest." : "\(count) newsletters wait for /digest.")
        }
        return parts.joined(separator: " ")
    }
}

/// Order confirmations, shipping notices, invoices and account mail: what people want to receive
/// even from senders whose ads they junk.
public enum TransactionalMail {
    /// Phrases, not single words: "Free delivery!" or "Kostenloser Versand" are ads.
    static let subjectPhrases = [
        // English
        "order confirm", "your order", "order #", "order no", "order number", "has shipped", "was shipped",
        "shipping confirm", "out for delivery", "has been delivered", "was delivered", "tracking number", "track your",
        "invoice", "receipt", "refund", "your return", "return label", "payment confirm", "payment received",
        "your payment", "password", "verification code", "security code", "verify your", "new sign-in", "new login",
        "your account",
        // German
        "ihre bestellung", "deine bestellung", "bestellbestätigung", "bestellnummer", "auftragsbestätigung",
        "versandbestätigung", "wurde versandt", "wurde versendet", "ist unterwegs", "ihre lieferung", "deine lieferung",
        "ihre sendung", "deine sendung", "sendungsverfolgung", "zustellung", "rechnung", "quittung", "retoure",
        "rücksendung", "erstattung", "gutschrift", "zahlungsbestätigung", "ihre zahlung", "deine zahlung", "passwort",
        "bestätigungscode", "sicherheitscode", "neue anmeldung", "ihr konto", "dein konto", "kundenkonto",
    ]
    static let senderParts = [
        "order", "bestellung", "shipping", "versand", "delivery", "lieferung", "invoice", "rechnung", "billing",
        "receipt", "payment", "zahlung", "account", "konto", "security", "returns", "retoure",
    ]

    public static func subjectMatches(_ subject: String) -> Bool {
        let subject = subject.lowercased()
        return subjectPhrases.contains { subject.contains($0) }
    }

    public static func looksTransactional(_ message: MailMessage) -> Bool {
        if subjectMatches(message.subject) { return true }
        let local = message.senderAddress.lowercased().split(separator: "@").first.map(String.init) ?? ""
        return senderParts.contains { local.contains($0) }
    }
}

/// Applies the automatic rules (read / archive / delete / junk) to messages. Only mail that arrived
/// after the rule was made is touched when `onlyNewerThanRule` is set (the background check), so a new
/// rule never sweeps through older mail on its own.
public enum RuleApplier {
    public struct Summary: Sendable, Hashable {
        public var markedRead = 0
        public var archived = 0
        public var deleted = 0
        public var junked = 0
        /// Message ids per action, for Undo and for the triage card.
        public var handled: [String: SenderAction] = [:]

        public init() {}

        public var total: Int { markedRead + archived + deleted + junked }

        public var text: String {
            [(junked, "to Junk"), (deleted, "deleted"), (archived, "archived"), (markedRead, "marked read")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        }
    }

    public static func apply(
        _ messages: [MailMessage], rules: SenderRuleBook, source: any MailSource, onlyNewerThanRule: Bool = false
    ) async throws -> Summary {
        var byAction: [SenderAction: [MailMessage]] = [:]
        for message in messages {
            guard let rule = rules.rule(for: message), rule.action.isAutomatic else { continue }
            if onlyNewerThanRule, message.date < rule.createdAt { continue }
            if rule.action == .markRead, message.isRead { continue }
            byAction[rule.action, default: []].append(message)
        }
        var summary = Summary()
        for (action, items) in byAction {
            let ids = items.map(\.id)
            switch action {
            case .markRead: summary.markedRead += try await source.markRead(ids: ids, true)
            case .archive: summary.archived += try await source.move(ids: ids, to: .archive, markRead: true)
            case .trash: summary.deleted += try await source.move(ids: ids, to: .trash, markRead: true)
            case .junk: summary.junked += try await source.move(ids: ids, to: .junk, markRead: true)
            default: continue
            }
            for id in ids { summary.handled[id] = action }
        }
        return summary
    }
}
