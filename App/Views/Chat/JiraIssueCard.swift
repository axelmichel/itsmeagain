import Jira
import SwiftUI

/// Jira tickets as cards: status, who has it, the gist of the description, the latest comments.
struct JiraIssueList: View {
    let issues: [JiraIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issues) { JiraIssueCard(issue: $0) }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

private struct JiraIssueCard: View {
    let issue: JiraIssue
    @State private var expanded = false

    private var statusColor: Color {
        switch issue.statusCategory {
        case "done": .green
        case "new": .secondary
        default: Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let url = URL(string: issue.url) {
                    Link(issue.key, destination: url).font(.callout.weight(.semibold).monospaced())
                } else {
                    Text(issue.key).font(.callout.weight(.semibold).monospaced())
                }
                Text(issue.status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.18))
                    .foregroundStyle(statusColor)
                Text(issue.type).font(.caption).foregroundStyle(.secondary)
                if let priority = issue.priority { Text(priority).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(issue.site).font(.caption).foregroundStyle(.tertiary)
            }
            Text(issue.summary).font(.body.weight(.medium))
            Text("\(issue.assignee ?? "Unassigned") · updated \(issue.updated.formatted(.relative(presentation: .named)))"
                 + (issue.reporter.map { " · reported by \($0)" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !issue.description.isEmpty {
                Text(expanded || issue.description.count <= 320 ? issue.description : String(issue.description.prefix(320)) + "…")
                    .font(.callout)
                    .textSelection(.enabled)
                if issue.description.count > 320 {
                    Button(expanded ? "Less" : "More") { expanded.toggle() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if !issue.comments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(issue.comments.suffix(3).enumerated()), id: \.offset) { _, comment in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(comment.author) · \(comment.created.formatted(.relative(presentation: .named)))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(comment.text.count > 400 ? String(comment.text.prefix(400)) + "…" : comment.text)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Theme.border.frame(width: 2) }
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.field)
    }
}
