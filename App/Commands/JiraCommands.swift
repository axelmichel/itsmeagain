import Commands
import Foundation
import Jira
import Persistence
import SwiftData

/// /jira <KEY…|words>, /myjira [site] — read-only, straight from the sites, no model.
extension AppModel {
    func runJiraCommand(_ handler: String, input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        guard jira.isConfigured else { return .failed("No Jira site is set up. Add one in Settings → Assistant → Jira.") }
        let argument = input.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if handler == "jira", argument.isEmpty { return .failed("Usage: /jira WTDEV-1857 (several keys allowed) or /jira <words>") }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        if conversation.messages.isEmpty { conversation.title = text }
        conversation.append(role: .user, content: text, task: .chat)
        let reply = conversation.append(role: .assistant, content: "_Asking Jira…_", task: .chat)
        try? context.save()
        let directory = jira.directory

        chat.run(in: conversation, context: context) {
            var failures: [String] = []
            if handler == "jira", case let keys = JiraDirectory.keys(in: argument.uppercased()), !keys.isEmpty {
                var issues: [JiraIssue] = []
                var missing: [String] = []
                for key in keys.prefix(10) {
                    let result = await directory.issue(key)
                    issues += result.value
                    failures += result.failures
                    if result.value.isEmpty { missing.append(key) }
                }
                reply.content = missing.isEmpty ? "" : "Not found: \(missing.joined(separator: ", "))."
                if !issues.isEmpty { reply.attachments = [.jiraIssues(issues)] }
            } else {
                let site = handler == "myjira" && !argument.isEmpty ? argument : nil
                let query = handler == "myjira" ? JiraQuery(mine: true) : JiraQuery(text: argument, updatedDays: 90)
                let result = await directory.search(query, site: site, limit: 30)
                failures = result.failures
                reply.content = Self.jiraMarkdown(result.value, grouped: handler == "myjira",
                                                  empty: handler == "myjira" ? "No open tickets assigned to you." : "No tickets match “\(argument)”.")
            }
            if !failures.isEmpty { reply.content += "\n\n_Not reachable: \(failures.joined(separator: "; "))_" }
        }
        return .handled
    }

    static func jiraMarkdown(_ issues: [JiraIssue], grouped: Bool, empty: String) -> String {
        guard !issues.isEmpty else { return empty }
        func line(_ issue: JiraIssue) -> String {
            let summary = issue.summary.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            return "- [\(issue.key)](\(issue.url)) \(summary) — _\(issue.status)\(grouped ? "" : ", \(issue.assignee ?? "unassigned")"), \(issue.updated.formatted(.relative(presentation: .named)))_"
        }
        guard grouped else { return issues.map(line).joined(separator: "\n") }
        let sites = Dictionary(grouping: issues, by: \.site)
        return sites.keys.sorted().map { site in
            let byStatus = Dictionary(grouping: sites[site]!, by: \.status)
            let order = ["indeterminate", "new"]
            let statuses = byStatus.keys.sorted { lhs, rhs in
                let left = order.firstIndex(of: byStatus[lhs]![0].statusCategory) ?? 9, right = order.firstIndex(of: byStatus[rhs]![0].statusCategory) ?? 9
                return (left, lhs) < (right, rhs)
            }
            return (sites.count > 1 ? "### \(site)\n" : "") + statuses.map { status in
                "**\(status)** (\(byStatus[status]!.count))\n" + byStatus[status]!.map(line).joined(separator: "\n")
            }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }
}
