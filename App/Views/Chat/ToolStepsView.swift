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
        .foregroundStyle(.secondary)
    }
}

private struct ToolStepRow: View {
    let step: ToolStep
    @State private var expanded = false

    var body: some View {
        if step.sources.isEmpty && step.error == nil {
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
            case .running: ProgressView().controlSize(.mini)
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
        default: "wrench.and.screwdriver"
        }
    }

    private var title: String {
        let running = step.status == .running
        switch step.tool {
        case "web_search": return "\(running ? "Searching" : "Searched") “\(step.subject)”"
        case "fetch_page": return "\(running ? "Reading" : "Read") \(SourceLink.shortURL(step.subject))"
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
