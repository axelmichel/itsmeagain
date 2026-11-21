import AppKit
import Obsidian
import Persistence
import SwiftData
import SwiftUI

/// Tasks from Obsidian notes; ticking writes the note (the user's own click), with Undo.
struct VaultTaskListView: View {
    let message: StoredMessage
    let index: Int
    let title: String
    let tasks: [VaultTask]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var busy: Set<String> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(tasks) { task in row(task) }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func row(_ task: VaultTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { toggle(task) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(busy.contains(task.id))
            .help(task.isDone ? "Mark as not done" : "Mark as done in the note")
            VStack(alignment: .leading, spacing: 2) {
                Text(task.text)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let due = task.due {
                        Text("📅 " + VaultTaskFormatter.day(due, calendar: .current))
                            .foregroundStyle(task.isDue() && !task.isDone ? Color.orange : Color.secondary)
                    }
                    if let link = vaultURL(task) {
                        Link(task.path, destination: link).lineLimit(1)
                    } else {
                        Text(task.path).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if busy.contains(task.id) { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.field)
    }

    private func vaultURL(_ task: VaultTask) -> URL? {
        app.detectedVaults.first { $0.name == task.vault }?.url(for: task.path)
    }

    private func toggle(_ task: VaultTask) {
        guard let vault = app.detectedVaults.first(where: { $0.name == task.vault }) else {
            error = "The vault “\(task.vault)” isn't available anymore."
            return
        }
        busy.insert(task.id)
        Task {
            do {
                let updated = try NoteStore(vault: vault).setDone(task, !task.isDone)
                store(tasks.map { $0.id == task.id ? updated : $0 })
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            busy.remove(task.id)
        }
    }

    private func store(_ updated: [VaultTask]) {
        var attachments = message.attachments
        guard attachments.indices.contains(index) else { return }
        attachments[index] = .vaultTasks(title: title, tasks: updated)
        message.attachments = attachments
        try? context.save()
    }
}
