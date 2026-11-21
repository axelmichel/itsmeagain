import CompanionCore
import Foundation

/// One Jira site the user connected (Cloud or Data Center). The token lives in the Keychain.
public struct JiraConnection: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case cloud, dataCenter }

    public var id: UUID
    public var name: String
    public var baseURL: String
    public var kind: Kind
    /// Cloud: the Atlassian account email (Basic auth with the API token). Data Center: unused (Bearer).
    public var email: String
    public var enabled: Bool
    /// Project keys on this site ("WTDEV"), to route ticket keys; refreshed by Test Connection.
    public var projectKeys: [String]
    public var lastChecked: Date?
    public var lastError: String?

    public init(id: UUID = UUID(), name: String, baseURL: String, kind: Kind = .cloud, email: String = "", enabled: Bool = true, projectKeys: [String] = []) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
        self.email = email
        self.enabled = enabled
        self.projectKeys = projectKeys
    }

    var apiVersion: String { kind == .cloud ? "3" : "2" }

    public var root: URL? {
        URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")))
    }

    /// "https://x.atlassian.net/browse/KEY-1"
    public func browseURL(_ key: String) -> URL? {
        root?.appending(path: "browse/\(key)")
    }
}

public struct JiraComment: Codable, Sendable, Hashable {
    public var author: String
    public var created: Date
    public var text: String
}

public struct JiraIssue: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    public var site: String
    public var url: String
    public var summary: String
    public var status: String
    /// "new" (To Do), "indeterminate" (In Progress), "done".
    public var statusCategory: String
    public var type: String
    public var priority: String?
    public var assignee: String?
    public var reporter: String?
    public var updated: Date
    public var description: String
    public var comments: [JiraComment]

    public var id: String { site + "/" + key }
}

public enum JiraError: LocalizedError, Equatable {
    case notConfigured(String)
    case unauthorized(String)
    case notFound(String)
    case http(Int, String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let site): "Jira “\(site)” isn't set up completely (address, email or token missing)."
        case .unauthorized(let site): "Jira “\(site)” refused the token (check email and token in Settings → Jira)."
        case .notFound(let what): "\(what) not found."
        case .http(let code, let site): "Jira “\(site)” answered HTTP \(code)."
        case .invalid(let message): message
        }
    }
}

/// Read-only REST client for one site: only GET requests exist in this type.
public struct JiraClient: Sendable {
    public let connection: JiraConnection
    let token: String
    let session: URLSession
    /// Tests only: allow plain http to a stub server. Real connections need https.
    let allowInsecure: Bool

    public init(connection: JiraConnection, token: String, session: URLSession = .shared, allowInsecure: Bool = false) {
        self.connection = connection
        self.token = token
        self.session = session
        self.allowInsecure = allowInsecure
    }

    // MARK: Requests

    func get(_ path: String, query: [String: String] = [:]) async throws -> Data {
        guard let root = connection.root, root.scheme == "https" || allowInsecure,
            !token.isEmpty, connection.kind == .dataCenter || !connection.email.isEmpty
        else { throw JiraError.notConfigured(connection.name) }
        var components = URLComponents(url: root.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch connection.kind {
        case .cloud:
            let basic = Data("\(connection.email):\(token)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        case .dataCenter:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        // Never follow the token to another host.
        if let final = response.url?.host(), final != root.host() { throw JiraError.invalid("Jira redirected to another host (\(final)).") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401, 403: throw JiraError.unauthorized(connection.name)
        case 404: throw JiraError.notFound(path)
        default: throw JiraError.http(code, connection.name)
        }
    }

    func json(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await get(path, query: query))
    }

    // MARK: API

    /// Cloud or Data Center, from the server itself.
    public func detectKind() async throws -> JiraConnection.Kind {
        let info = try await json("rest/api/2/serverInfo")
        return info["deploymentType"]?.stringValue?.lowercased() == "cloud" ? .cloud : .dataCenter
    }

    public func myself() async throws -> String {
        let me = try await json("rest/api/\(connection.apiVersion)/myself")
        return me["displayName"]?.stringValue ?? me["name"]?.stringValue ?? "?"
    }

    public func projectKeys() async throws -> [String] {
        if connection.kind == .cloud {
            var keys: [String] = []
            var start = 0
            while start < 1_000 {
                let page = try await json("rest/api/3/project/search", query: ["startAt": "\(start)", "maxResults": "100"])
                guard case .array(let values)? = page["values"] else { break }
                keys += values.compactMap { $0["key"]?.stringValue }
                if page["isLast"] == .bool(true) || values.isEmpty { break }
                start += values.count
            }
            return keys
        }
        guard case .array(let values) = try await json("rest/api/2/project") else { return [] }
        return values.compactMap { $0["key"]?.stringValue }
    }

    static let fields = "summary,status,assignee,reporter,priority,issuetype,updated,description,comment"

    public func issue(_ key: String, comments: Int = 5) async throws -> JiraIssue {
        guard key.range(of: #"^[A-Z][A-Z0-9_]+-\d+$"#, options: .regularExpression) != nil else {
            throw JiraError.invalid("“\(key)” isn't a ticket key.")
        }
        let raw = try await json("rest/api/\(connection.apiVersion)/issue/\(key)", query: ["fields": Self.fields])
        return try parse(raw, comments: comments)
    }

    public func search(jql: String, limit: Int = 20) async throws -> [JiraIssue] {
        let path = connection.kind == .cloud ? "rest/api/3/search/jql" : "rest/api/2/search"
        let raw = try await json(path, query: ["jql": jql, "maxResults": "\(min(max(limit, 1), 50))", "fields": Self.fields])
        guard case .array(let issues)? = raw["issues"] else { return [] }
        return issues.compactMap { try? parse($0, comments: 0) }
    }

    // MARK: Parsing

    func parse(_ raw: JSONValue, comments limit: Int) throws -> JiraIssue {
        guard let key = raw["key"]?.stringValue, let fields = raw["fields"] else { throw JiraError.invalid("Unexpected Jira answer.") }
        let description = JiraText.text(fields["description"])
        var comments: [JiraComment] = []
        if limit > 0, case .array(let list)? = fields["comment"]?["comments"] {
            comments = list.suffix(limit).map { comment in
                JiraComment(
                    author: comment["author"]?["displayName"]?.stringValue ?? "?",
                    created: Self.date(comment["created"]?.stringValue) ?? .distantPast,
                    text: JiraText.text(comment["body"])
                )
            }
        }
        return JiraIssue(
            key: key, site: connection.name, url: connection.browseURL(key)?.absoluteString ?? "",
            summary: fields["summary"]?.stringValue ?? "",
            status: fields["status"]?["name"]?.stringValue ?? "?",
            statusCategory: fields["status"]?["statusCategory"]?["key"]?.stringValue ?? "indeterminate",
            type: fields["issuetype"]?["name"]?.stringValue ?? "",
            priority: fields["priority"]?["name"]?.stringValue,
            assignee: fields["assignee"]?["displayName"]?.stringValue,
            reporter: fields["reporter"]?["displayName"]?.stringValue,
            updated: Self.date(fields["updated"]?.stringValue) ?? .distantPast,
            description: description, comments: comments
        )
    }

    /// "2026-11-21T10:15:30.000+0100"
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return try? Date(text, strategy: .iso8601)
    }
}

/// Description and comment bodies → plain text: Atlassian Document Format (Cloud) or wiki markup (Data Center).
public enum JiraText {
    public static func text(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let string = value.stringValue { return wiki(string) }
        var out = ""
        adf(value, into: &out)
        return out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func adf(_ node: JSONValue, into out: inout String, listDepth: Int = 0) {
        let type = node["type"]?.stringValue ?? ""
        switch type {
        case "text":
            var text = node["text"]?.stringValue ?? ""
            if case .array(let marks)? = node["marks"],
                let link = marks.first(where: { $0["type"]?.stringValue == "link" })?["attrs"]?["href"]?.stringValue, link != text
            {
                text += " (\(link))"
            }
            out += text
            return
        case "hardBreak": out += "\n"; return
        case "mention": out += node["attrs"]?["text"]?.stringValue ?? "@?"; return
        case "emoji": out += node["attrs"]?["text"]?.stringValue ?? ""; return
        case "inlineCard", "blockCard": out += node["attrs"]?["url"]?.stringValue ?? ""; return
        case "listItem": out += String(repeating: "  ", count: max(listDepth - 1, 0)) + "- "
        case "codeBlock": out += "```\n"
        default: break
        }
        if case .array(let children)? = node["content"] {
            let depth = (type == "bulletList" || type == "orderedList") ? listDepth + 1 : listDepth
            for child in children { adf(child, into: &out, listDepth: depth) }
        }
        switch type {
        case "paragraph", "heading", "listItem", "blockquote", "rule", "panel": if !out.hasSuffix("\n") { out += "\n" }
        case "codeBlock": out += "\n```\n"
        default: break
        }
    }

    /// Data Center wiki markup: strip the common markers, keep the text.
    static func wiki(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"\{code(:[^}]*)?\}"#, "```"), (#"\{noformat\}"#, "```"), (#"\{quote\}"#, ""), (#"\{color(:[^}]*)?\}"#, ""),
            (#"(?m)^h[1-6]\.\s*"#, ""), (#"\[([^|\]]+)\|([^\]]+)\]"#, "$1 ($2)"), (#"\[~([^\]]+)\]"#, "@$1"),
            (#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "$1"), (#"(?<![\w_])_([^_\n]+)_(?![\w_])"#, "$1"),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
