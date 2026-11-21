import Persistence
import PersonalData
import SwiftData
import SwiftUI

/// A reminder list in the transcript: tick off (with undo), move the due date, delete.
/// Actions go straight to EventKit — they're the user's own clicks, so no approval card.
struct ReminderListView: View {
    let message: StoredMessage
    let index: Int
    let title: String
    let items: [ReminderItem]
    @Environment(\.modelContext) private var context
    @State private var error: String?
    @State private var busy: Set<String> = []
    @State private var pendingDelete: ReminderItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            if items.isEmpty {
                Text("Nothing left.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(items) { item in
                    ReminderRow(
                        item: item,
                        busy: busy.contains(item.id),
                        onToggle: { perform(item) { try await $0.setReminderCompleted(id: item.id, !item.isCompleted) } },
                        onDue: { choice in
                            let (due, hasTime) = choice.date(keepingTimeOf: item)
                            perform(item) { try await $0.setReminderDue(id: item.id, due: due, hasTime: hasTime) }
                        },
                        onDelete: { pendingDelete = item }
                    )
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Reminder", role: .destructive) {
                guard let item = pendingDelete else { return }
                delete(item)
            }
        } message: {
            Text("This removes it from Reminders on all your devices.")
        }
        .task { await refresh() }
    }

    // MARK: Actions

    private func perform(_ item: ReminderItem, _ action: @escaping (EventKitStore) async throws -> ReminderItem) {
        busy.insert(item.id)
        Task {
            do {
                let updated = try await action(EventKitStore.shared)
                store(items.map { $0.id == item.id ? updated : $0 })
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            busy.remove(item.id)
        }
    }

    private func delete(_ item: ReminderItem) {
        busy.insert(item.id)
        Task {
            do {
                try await EventKitStore.shared.deleteReminder(id: item.id)
                store(items.filter { $0.id != item.id })
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            busy.remove(item.id)
        }
    }

    /// Picks up changes made elsewhere (iPhone, Reminders app); reminders deleted there disappear.
    private func refresh() async {
        guard EventKitStore.remindersAuthorized else { return }
        var fresh: [ReminderItem] = []
        for item in items {
            guard let current = try? await EventKitStore.shared.reminder(id: item.id) else { continue }
            fresh.append(current)
        }
        if fresh != items { store(fresh) }
    }

    private func store(_ updated: [ReminderItem]) {
        var attachments = message.attachments
        guard attachments.indices.contains(index) else { return }
        attachments[index] = .reminders(title: title, items: updated)
        message.attachments = attachments
        try? context.save()
    }
}

private struct ReminderRow: View {
    let item: ReminderItem
    let busy: Bool
    let onToggle: () -> Void
    let onDue: (ReminderDueChoice) -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    private var overdue: Bool {
        guard let due = item.due, !item.isCompleted else { return false }
        return due < (item.dueHasTime ? .now : Calendar.current.startOfDay(for: .now))
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? Theme.accent : .secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(item.isCompleted ? "Mark as not done" : "Mark as done")

            Text(item.title)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? .secondary : .primary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if item.isCompleted {
                Button("Undo", action: onToggle)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(busy)
            } else {
                Menu {
                    ForEach(ReminderDueChoice.allCases) { choice in
                        Button(choice.title) { onDue(choice) }
                    }
                } label: {
                    Text(dueLabel)
                        .font(.caption)
                        .foregroundStyle(overdue ? Color.orange : Color.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(busy)
                .help("Change the due date")
            }

            Text(item.list)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovered ? Theme.hover : Theme.field)
        .onHover { hovered = $0 }
        .contextMenu {
            Button(item.isCompleted ? "Mark as Not Done" : "Mark as Done", action: onToggle)
            Menu("Due") {
                ForEach(ReminderDueChoice.allCases) { choice in
                    Button(choice.title) { onDue(choice) }
                }
            }
            Divider()
            Button("Delete Reminder…", role: .destructive, action: onDelete)
        }
    }

    private var dueLabel: String {
        guard let due = item.due else { return "No date" }
        let calendar = Calendar.current
        let day: String = calendar.isDateInToday(due) ? "Today"
            : calendar.isDateInTomorrow(due) ? "Tomorrow"
            : calendar.isDateInYesterday(due) ? "Yesterday"
            : due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return item.dueHasTime ? "\(day) \(ToolDate.time(due))" : day
    }
}
