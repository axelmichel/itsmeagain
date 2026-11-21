import CompanionCore
import Foundation
import Tools

/// All connected Jira sites: routes ticket keys to the right site(s), searches across all of them.
/// One failing site never hides the others' results.
public struct JiraDirectory: Sendable {
    public let clients: [JiraClient]

    public init(clients: [JiraClient]) {
        self.clients = clients
    }

    public struct Result<Value: Sendable>: Sendable {
        public var value: Value
        /// "Site: error" for sites that failed.
        public var failures: [String]
    }

    /// Ticket keys in free text ("see WTDEV-1857 and OPS-12").
    public static func keys(in text: String) -> [String] {
        let matches = text.matches(of: /\b([A-Z][A-Z0-9_]{1,15}-\d{1,7})\b/).map { String($0.output.1) }
        var seen = Set<String>()
        return matches.filter { seen.insert($0).inserted }
    }

    /// Sites whose project list contains the key's prefix; all sites when none (or no list yet) matches.
    public func sites(for key: String) -> [JiraClient] {
        let prefix = key.split(separator: "-").first.map(String.init) ?? key
        let known = clients.filter { $0.connection.projectKeys.contains(prefix) }
        return known.isEmpty ? clients : known
    }

    public func issue(_ key: String) async -> Result<[JiraIssue]> {
        let candidates = sites(for: key)
        var found: [JiraIssue] = []
        var failures: [String] = []
        await withTaskGroup(of: (String, Swift.Result<JiraIssue, Error>).self) { group in
            for client in candidates {
                group.addTask {
                    do { return (client.connection.name, .success(try await client.issue(key))) } catch { return (client.connection.name, .failure(error)) }
                }
            }
            for await (site, result) in group {
                switch result {
                case .success(let issue): found.append(issue)
                case .failure(JiraError.notFound): break  // not on this site
                case .failure(let error): failures.append("\(site): \(error.localizedDescription)")
                }
            }
        }
        return Result(value: found.sorted { $0.site < $1.site }, failures: failures)
    }

    public func search(_ query: JiraQuery, site: String? = nil, limit: Int = 20) async -> Result<[JiraIssue]> {
        let targets = site.map { name in clients.filter { $0.connection.name.localizedCaseInsensitiveCompare(name) == .orderedSame } } ?? clients
        var found: [JiraIssue] = []
        var failures: [String] = []
        await withTaskGroup(of: (String, Swift.Result<[JiraIssue], Error>).self) { group in
            for client in targets {
                group.addTask {
                    do { return (client.connection.name, .success(try await client.search(jql: query.jql, limit: limit))) } catch { return (client.connection.name, .failure(error)) }
                }
            }
            for await (site, result) in group {
                switch result {
                case .success(let issues): found += issues
                case .failure(let error): failures.append("\(site): \(error.localizedDescription)")
                }
            }
        }
        return Result(value: found.sorted { $0.updated > $1.updated }, failures: failures)
    }
}

/// Simple filters the app turns into JQL — the model never writes JQL itself.
public struct JiraQuery: Sendable, Hashable {
    public var text: String?
    public var mine: Bool
    public var openOnly: Bool
    public var updatedDays: Int?
    public var project: String?

    public init(text: String? = nil, mine: Bool = false, openOnly: Bool = true, updatedDays: Int? = nil, project: String? = nil) {
        self.text = text
        self.mine = mine
        self.openOnly = openOnly
        self.updatedDays = updatedDays
        self.project = project
    }

    public var jql: String {
        var clauses: [String] = []
        if mine { clauses.append("assignee = currentUser()") }
        if openOnly { clauses.append("statusCategory != Done") }
        if let days = updatedDays, days > 0 { clauses.append("updated >= -\(min(days, 365))d") }
        if let project, project.range(of: #"^[A-Z][A-Z0-9_]+$"#, options: .regularExpression) != nil { clauses.append("project = \(project)") }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            clauses.append("text ~ \"\(escaped)\"")
        }
        if clauses.isEmpty { clauses.append("updated >= -7d") }
        return clauses.joined(separator: " AND ") + " ORDER BY updated DESC"
    }
}

// MARK: Tools (private: work data; local models only)

public enum JiraFormatter {
    public static func line(_ issue: JiraIssue) -> String {
        "\(issue.key) [\(issue.status)] \(issue.summary) — \(issue.assignee ?? "unassigned") · \(issue.site) · updated \(issue.updated.formatted(.relative(presentation: .named)))"
    }

    public static func detail(_ issue: JiraIssue) -> String {
        var text = line(issue) + "\nType: \(issue.type)" + (issue.priority.map { " · Priority: \($0)" } ?? "") + (issue.reporter.map { " · Reporter: \($0)" } ?? "")
        let description = issue.description.count > 4_000 ? String(issue.description.prefix(4_000)) + " […]" : issue.description
        if !description.isEmpty { text += "\n\nDescription:\n" + description }
        if !issue.comments.isEmpty {
            text += "\n\nLatest comments:\n" + issue.comments.map { comment in
                "- \(comment.author), \(comment.created.formatted(date: .abbreviated, time: .shortened)): \(comment.text.prefix(600))"
            }.joined(separator: "\n")
        }
        return text
    }
}

public struct JiraIssueTool: Tool {
    let directory: JiraDirectory
    public init(directory: JiraDirectory) { self.directory = directory }

    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        ToolSpec(
            name: "jira_issue",
            description: "One Jira ticket by key (e.g. WTDEV-1857): status, assignee, description, latest comments. Read-only.",
            parameters: ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let key = try arguments.requiredString("key").uppercased()
        let result = await directory.issue(key)
        guard !result.value.isEmpty else {
            throw ToolError.failed("\(key) wasn't found" + (result.failures.isEmpty ? "." : " (\(result.failures.joined(separator: "; ")))."))
        }
        let text = result.value.map(JiraFormatter.detail).joined(separator: "\n\n---\n\n")
        let sources = result.value.compactMap { issue in issue.url.isEmpty ? nil : SourceRef(title: "\(issue.key) \(issue.summary)", url: issue.url) }
        return ToolOutput(content: Untrusted.wrap(text, source: "jira"), sources: sources)
    }
}

public struct JiraSearchTool: Tool {
    let directory: JiraDirectory
    public init(directory: JiraDirectory) { self.directory = directory }

    public var dataClass: ToolDataClass { .private }

    public var spec: ToolSpec {
        let sites = directory.clients.map(\.connection.name).joined(separator: ", ")
        return ToolSpec(
            name: "jira_search",
            description: "Find Jira tickets across the user's sites (\(sites)). Read-only. Returns key, status, summary, assignee.",
            parameters: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "Words to search for (optional)"],
                    "mine": ["type": "boolean", "description": "Only tickets assigned to the user"],
                    "open_only": ["type": "boolean", "description": "Exclude done tickets (default true)"],
                    "updated_days": ["type": "integer", "description": "Only tickets updated in the last n days"],
                    "project": ["type": "string", "description": "Project key, e.g. WTDEV"],
                    "site": ["type": "string", "description": "One site by name (optional)"],
                ],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let query = JiraQuery(
            text: arguments["text"]?.stringValue, mine: arguments["mine"] == .bool(true),
            openOnly: arguments["open_only"] != .bool(false), updatedDays: arguments["updated_days"]?.intValue,
            project: arguments["project"]?.stringValue?.uppercased()
        )
        let result = await directory.search(query, site: arguments["site"]?.stringValue)
        var text = result.value.isEmpty ? "No matching tickets." : result.value.map(JiraFormatter.line).joined(separator: "\n")
        if !result.failures.isEmpty { text += "\n(Not reachable: \(result.failures.joined(separator: "; ")))" }
        return ToolOutput(content: Untrusted.wrap(text, source: "jira"))
    }
}
