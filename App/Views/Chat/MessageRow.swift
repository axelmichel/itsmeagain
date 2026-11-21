import AppKit
import CompanionCore
import Persistence
import SwiftUI

struct MessageRow: View {
    let message: StoredMessage
    let isStreaming: Bool
    /// Deletes the message; for a question, `withAnswer` also removes its replies. Nil while a reply runs.
    var onDelete: ((_ withAnswer: Bool) -> Void)?
    /// The current find-bar match gets an outline.
    var isCurrentMatch = false
    @Environment(\.searchHighlight) private var highlight
    @State private var hovered = false

    var body: some View {
        content
            .overlay {
                if isCurrentMatch {
                    Rectangle().stroke(Theme.accent, lineWidth: 1.5).padding(-6)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Sits in the gap above the message, so it never covers text.
                if hovered && !(isStreaming && message.content.isEmpty) {
                    actionsMenu.offset(y: -17)
                }
            }
            .onHover { hovered = $0 }
            .contextMenu { actions }
    }

    private var actionsMenu: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18)
                .background(Theme.field)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy or delete")
    }

    @ViewBuilder
    private var actions: some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        }
        if let onDelete {
            Divider()
            if message.role == .user {
                Button("Delete Question and Answer", role: .destructive) { onDelete(true) }
                Button("Delete Question Only", role: .destructive) { onDelete(false) }
            } else {
                Button("Delete Answer", role: .destructive) { onDelete(false) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(MarkdownView.highlighted(AttributedString(message.content), highlight))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.selection)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                if !message.thinking.isEmpty {
                    DisclosureGroup {
                        Text(message.thinking)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    } label: {
                        Text("Thinking")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    .tint(.secondary)
                }
                let steps = message.toolSteps
                if !steps.isEmpty {
                    ToolStepsView(steps: steps)
                }
                if message.content.isEmpty && isStreaming {
                    ProgressView().controlSize(.small)
                } else {
                    MarkdownView(markdown: message.content)
                }
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { index, attachment in
                    switch attachment {
                    case .reminders(let title, let items):
                        ReminderListView(message: message, index: index, title: title, items: items)
                    case .mailCleanup(let groups):
                        MailCleanupView(message: message, index: index, groups: groups)
                    case .calendar(let style, let date):
                        CalendarCardView(message: message, index: index, style: style, date: date)
                    }
                }
                if let error = message.errorText {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if let model = message.modelID {
                    Label(
                        [message.task?.title, model].compactMap(\.self).joined(separator: " · "),
                        systemImage: message.task?.systemImage ?? "cpu"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

extension EnvironmentValues {
    /// Text the find bar is looking for; MarkdownView and questions highlight it.
    @Entry var searchHighlight: String?
}

struct MarkdownView: View {
    let markdown: String
    @Environment(\.searchHighlight) private var highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(Self.highlighted(Self.attributed(text), highlight))
                        .textSelection(.enabled)
                case .heading(let level, let text):
                    Text(Self.highlighted(Self.attributed(text), highlight))
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                case .rule:
                    Divider()
                case .code(let language, let code):
                    CodeBlock(language: language, code: code)
                }
            }
        }
    }

    /// Marks every occurrence of `query` (case- and diacritic-insensitive).
    static func highlighted(_ text: AttributedString, _ query: String?) -> AttributedString {
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return text }
        var result = text
        let plain = String(result.characters)
        var searchRange = plain.startIndex..<plain.endIndex
        while let found = plain.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let start = plain.distance(from: plain.startIndex, to: found.lowerBound)
            let length = plain.distance(from: found.lowerBound, to: found.upperBound)
            let lower = result.index(result.startIndex, offsetByCharacters: start)
            let upper = result.index(lower, offsetByCharacters: length)
            result[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
            searchRange = found.upperBound..<plain.endIndex
        }
        return result
    }

    private static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal) {
                Text(CodeHighlighter.shared.highlight(code, language: language, dark: colorScheme == .dark) ?? AttributedString(code))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Theme.recessed)
        .overlay(Rectangle().strokeBorder(Theme.border.opacity(0.6)))
    }
}
