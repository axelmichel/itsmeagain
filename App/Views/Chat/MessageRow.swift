import AppKit
import CompanionCore
import Persistence
import SwiftUI

struct MessageRow: View {
    let message: StoredMessage
    let isStreaming: Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
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

struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(Self.attributed(text))
                        .textSelection(.enabled)
                case .heading(let level, let text):
                    Text(Self.attributed(text))
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

    private static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct CodeBlock: View {
    let language: String?
    let code: String

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
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Theme.recessed)
        .overlay(Rectangle().strokeBorder(Theme.border.opacity(0.6)))
    }
}
