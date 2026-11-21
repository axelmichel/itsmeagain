import Commands
import SwiftUI

/// The `/` completion list shown above the editor (and in the quick panel).
struct CommandSuggestions: View {
    let commands: [CommandSpec]
    let selected: Int
    let onPick: (CommandSpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button { onPick(command) } label: {
                    HStack(spacing: 8) {
                        Text("/\(command.name)")
                            .font(.callout.monospaced().weight(.medium))
                        if let hint = command.argumentHint {
                            Text(hint)
                                .font(.callout.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 12)
                        Text(command.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if case .user = command.source {
                            Image(systemName: "person.crop.circle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .help("Your command")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == selected ? Theme.selection : .clear)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(.vertical, 4)
        .background(Theme.field)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }
}

/// Shared completion behaviour for the editor and the quick panel.
@MainActor
struct CommandCompletion {
    var registry: CommandRegistry
    var text: String
    var dismissed: Bool

    static let limit = 8

    var suggestions: [CommandSpec] {
        dismissed ? [] : Array(registry.completions(for: text).prefix(Self.limit))
    }

    /// While arguments are being typed: the matched command's hint.
    var argumentHint: String? {
        guard let input = CommandInput(text), text.contains(where: \.isWhitespace),
            let command = registry.command(named: input.name)
        else { return nil }
        return "/\(command.name)" + (command.argumentHint.map { " \($0)" } ?? "") + " — \(command.summary)"
    }

    /// Text after accepting a suggestion: "/name " ready for arguments.
    static func accepted(_ command: CommandSpec) -> String {
        "/\(command.name) "
    }
}
