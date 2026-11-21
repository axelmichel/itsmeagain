import AppKit
import Commands
import SwiftUI

/// Built-in and user commands; user commands are Markdown files in the Commands folder.
struct CommandSettings: View {
    @Environment(AppModel.self) private var app

    private var center: CommandCenter { app.commands }

    var body: some View {
        Form {
            Section {
                ForEach(center.registry.commands) { command in
                    CommandRow(command: command)
                }
            } header: {
                Text("Commands")
            } footer: {
                Text("Type / in the message field or the quick panel. Personal commands always run in Chat mode.")
                    .foregroundStyle(.secondary)
            }

            if !center.fileErrors.isEmpty || !center.registry.conflicts.isEmpty {
                Section("Problems") {
                    ForEach(center.fileErrors) { error in
                        LabeledContent(URL(filePath: error.path).lastPathComponent) {
                            Text(error.message).foregroundStyle(.orange)
                        }
                    }
                    ForEach(center.registry.conflicts, id: \.self) { conflict in
                        Text(conflict).foregroundStyle(.orange)
                    }
                }
            }

            Section {
                HStack {
                    Button("New Command…") {
                        NSWorkspace.shared.open(center.createCommandFile())
                    }
                    Button("Open Commands Folder") {
                        NSWorkspace.shared.open(center.directory)
                    }
                    Spacer()
                    Button("Reload") { center.reload() }
                }
            } footer: {
                Text("Each .md file is one command: a short header (description, argument-hint, task, tools …) and the prompt. Changes are picked up automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}

private struct CommandRow: View {
    let command: CommandSpec

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/\(command.name)").font(.body.monospaced())
                    if let hint = command.argumentHint {
                        Text(hint).font(.callout.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                Text(command.summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if command.scope == .personal {
                Text("Personal").font(.caption).foregroundStyle(.secondary)
            }
            switch command.source {
            case .builtIn:
                Text("Built-in").font(.caption).foregroundStyle(.tertiary)
            case .user(let path):
                Button("Edit") { NSWorkspace.shared.open(URL(filePath: path)) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }
}
