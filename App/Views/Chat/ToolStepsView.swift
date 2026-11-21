import Persistence
import SwiftUI
import Tools

/// The tool calls of a reply: "Searched …", "Read …", each expandable to its sources.
struct ToolStepsView: View {
    let steps: [ToolStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps) { step in
                ToolStepRow(step: step)
            }
        }
        .font(.callout)
        .foregroundStyle(.tertiary)
        .tint(.secondary)
    }
}

private struct ToolStepRow: View {
    let step: ToolStep
    @State private var expanded = false

    var body: some View {
        if step.status == .awaitingApproval {
            ApprovalCard(step: step)
        } else if step.sources.isEmpty && step.error == nil {
            label
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = step.error {
                        Text(error).foregroundStyle(.orange)
                    }
                    ForEach(step.sources, id: \.url) { source in
                        SourceLink(source: source)
                    }
                }
                .padding(.leading, 4)
                .padding(.vertical, 2)
            } label: {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            switch step.status {
            case .running, .awaitingApproval: ProgressView().controlSize(.mini)
            case .done: Image(systemName: icon)
            case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var icon: String {
        switch step.tool {
        case "web_search": "magnifyingglass"
        case "fetch_page": "doc.text"
        case "search_documents": "folder"
        default: "wrench.and.screwdriver"
        }
    }

    private var title: String {
        let running = step.status == .running
        switch step.tool {
        case "web_search": return "\(running ? "Searching" : "Searched") “\(step.subject)”"
        case "fetch_page": return "\(running ? "Reading" : "Read") \(SourceLink.shortURL(step.subject))"
        case "search_documents": return "\(running ? "Searching" : "Searched") your documents for “\(step.subject)”"
        default: return "\(running ? "Running" : "Ran") \(step.tool)"
        }
    }
}

struct SourceLink: View {
    let source: SourceRef

    var body: some View {
        if let url = URL(string: source.url) {
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title).lineLimit(1)
                    Text(Self.shortURL(source.url))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .help(source.url)
        }
    }

    /// "example.com/a/b" without scheme and "www.".
    static func shortURL(_ string: String) -> String {
        guard let url = URL(string: string), let host = url.host() else { return string }
        let path = url.path() == "/" ? "" : url.path()
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path
    }
}

/// A write the assistant wants to make: nothing happens until the user approves.
private struct ApprovalCard: View {
    let step: ToolStep
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Needs your approval", systemImage: "hand.raised")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text(step.approvalSummary ?? step.tool)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Approve") { app.approvals.resolve(step.id, granted: true) }
                    .keyboardShortcut(.defaultAction)
                Button("Deny") { app.approvals.resolve(step.id, granted: false) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.selection)
        .overlay(alignment: .leading) { Theme.accent.frame(width: 2) }
    }
}
