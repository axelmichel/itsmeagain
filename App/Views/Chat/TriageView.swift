import AppKit
import Mail
import Persistence
import SwiftData
import SwiftUI

/// The /triage card — where the assistant learns your mail.
/// - Every mail can be ticked (read, unread, moved); a group heading ticks the whole group.
/// - Right-click a mail: the action applies to the selection if the mail is part of it, else to that mail.
/// - The selection bar shows above the card and at every group with ticked mails.
/// - Unread: blue dot, bold sender and subject. Read: plain, grey.
/// Everything is your own click; replies only ever open as drafts in Mail.
struct TriageView: View {
    let message: StoredMessage
    let index: Int
    let items: [TriageItem]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var busy: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var selection: Set<String> = []
    @State private var showMoved = false

    /// Mails gone to Junk or Trash never count as selected (they're no longer in the list).
    private var selected: [TriageItem] { items.filter { selection.contains($0.id) && !isGone($0) } }

    /// Junked and deleted mail is gone from the inbox, so it leaves the list too (kept below only for Undo).
    private func isGone(_ item: TriageItem) -> Bool { item.handled == .junked || item.handled == .deleted }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !selected.isEmpty { selectionBar }
            ForEach(TriageItem.Category.allCases, id: \.self) { category in
                let group = items.filter { $0.category == category && !isGone($0) }
                if !group.isEmpty { section(category, group) }
            }
            let gone = items.filter(isGone)
            if !gone.isEmpty {
                DisclosureGroup("Moved to Junk or Trash (\(gone.count))", isExpanded: $showMoved) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(gone) { item in
                            HStack {
                                Text(item.message.senderName).lineLimit(1)
                                Text(item.message.subject).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(item.handled == .junked ? "Junk" : "Trash").font(.caption).foregroundStyle(.secondary)
                                Button("Move Back") { moveBack([item]) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.field)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    // MARK: Layout

    private func section(_ category: TriageItem.Category, _ group: [TriageItem]) -> some View {
        let ids = group.map(\.id)
        let allSelected = ids.allSatisfy { selection.contains($0) }
        let unread = group.filter { !$0.message.isRead && $0.handled == nil }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { allSelected },
                    set: { on in if on { selection.formUnion(ids) } else { selection.subtract(ids) } }
                )) {
                    Text("\(category.title) (\(group.count)\(unread > 0 ? ", \(unread) unread" : ""))")
                        .font(.callout.weight(.semibold))
                }
                .toggleStyle(.checkbox)
                .help("Select the whole group")
                Spacer()
            }
            // The actions also sit here, next to where you are ticking.
            if group.contains(where: { selection.contains($0.id) }) { selectionBar }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(group) { item in
                    TriageRow(
                        item: item,
                        rule: app.senderRules.action(for: item.message),
                        isSelected: Binding(
                            get: { selection.contains(item.id) },
                            set: { on in if on { selection.insert(item.id) } else { selection.remove(item.id) } }
                        ),
                        busy: busy.contains(item.id),
                        error: errors[item.id],
                        onReply: { reply(to: item, intent: $0) }
                    )
                    .contextMenu { menu(for: targets(item)) }
                }
            }
        }
    }

    /// The selected mails if this one is part of the selection, otherwise just this one.
    private func targets(_ item: TriageItem) -> [TriageItem] {
        selection.contains(item.id) ? selected : [item]
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selected.count) selected").font(.callout.weight(.medium))
            Button("Mark Read") { setRead(selected, true) }
            Button("Mark Unread") { setRead(selected, false) }
            Button("Archive") { move(selected, to: .archived) }
            Button("Delete") { move(selected, to: .deleted) }
            Menu("More") { menu(for: selected) }
                .menuStyle(.borderlessButton)
                .fixedSize()
            Spacer()
            Button("Clear") { selection.removeAll() }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.selection)
    }

    /// Right-click menu and the bar's "More" menu.
    @ViewBuilder
    private func menu(for targets: [TriageItem]) -> some View {
        let count = targets.count
        Text(count == 1 ? targets[0].message.subject : "\(count) mails")
        Divider()
        Button("Mark as Read") { setRead(targets, true) }
        Button("Mark as Unread") { setRead(targets, false) }
        Button("Archive") { move(targets, to: .archived) }
        Button("Delete") { move(targets, to: .deleted) }
        Button("Move to Junk") { move(targets, to: .junked) }
        if targets.contains(where: { $0.handled != nil && $0.handled != .replied }) {
            Button("Move Back to Inbox") { moveBack(targets) }
        }
        Divider()
        Menu("From now on, mail from \(count == 1 ? targets[0].message.senderName : "these senders") …") {
            ForEach(SenderAction.allCases, id: \.self) { action in
                Button(action.explanation.prefix(1).uppercased() + action.explanation.dropFirst()) { rule(action, for: targets) }
            }
        }
        Menu("Group as") {
            ForEach(TriageItem.Category.allCases, id: \.self) { category in
                Button(category.title) { regroup(targets, as: category) }
            }
        }
        if count == 1, let url = targets[0].message.url {
            Divider()
            Button("Open in Mail") { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: Actions

    /// Where a mail is now, so the next action looks there first.
    private func location(_ item: TriageItem) -> MailDestination {
        switch item.handled {
        case .archived?: .archive
        case .deleted?: .trash
        case .junked?: .junk
        default: .inbox
        }
    }

    private func setRead(_ targets: [TriageItem], _ read: Bool) {
        selection.subtract(targets.map(\.id))
        let changing = targets.filter { $0.message.isRead != read && $0.handled != .deleted }
        guard !changing.isEmpty else { return }
        let ids = changing.map(\.id)
        perform(ids) { source in
            _ = try await source.markRead(ids: ids, read)
            update(ids) { $0.message.isRead = read }
        }
    }

    private func move(_ targets: [TriageItem], to destination: TriageItem.Handled) {
        selection.subtract(targets.map(\.id))
        // Nothing to do for mails already there; deleted mail isn't deleted twice (that would be permanent).
        let moving = targets.filter { $0.handled != destination && $0.handled != .deleted }
        guard !moving.isEmpty else { return }
        let target: MailDestination = switch destination {
        case .archived: .archive
        case .junked: .junk
        default: .trash
        }
        // One call per current location, so each mail is looked up where it is.
        let byOrigin = Dictionary(grouping: moving, by: location)
        perform(moving.map(\.id)) { source in
            for (origin, group) in byOrigin {
                let ids = group.map(\.id)
                let moved = try await source.move(ids: ids, to: target, markRead: true, from: origin)
                if moved == 0 { throw MailError.script("Mail couldn't find these messages anymore.") }
                update(ids) {
                    $0.handled = destination
                    $0.message.isRead = true
                }
            }
        }
    }

    private func moveBack(_ targets: [TriageItem]) {
        selection.subtract(targets.map(\.id))
        let moved = targets.filter { $0.handled != nil && $0.handled != .replied }
        guard !moved.isEmpty else { return }
        let byOrigin = Dictionary(grouping: moved, by: location)
        perform(moved.map(\.id)) { source in
            for (origin, group) in byOrigin {
                let ids = group.map(\.id)
                _ = try await source.move(ids: ids, to: .inbox, markRead: false, from: origin)
                update(ids) { $0.handled = nil }
            }
            // Undoing what a rule did means the rule was wrong for that sender.
            for item in moved {
                if let rule = app.senderRules.action(for: item.message), rule.isAutomatic {
                    app.senderRules.remove(item.message.senderAddress)
                }
            }
        }
    }

    /// Saves the rule per sender, then applies it to this card's mails it covers
    /// (order and account mail stays, as with every rule).
    private func rule(_ action: SenderAction, for targets: [TriageItem]) {
        for address in Set(targets.map(\.message.senderAddress)) {
            app.senderRules.set(address, action, name: targets.first { $0.message.senderAddress == address }?.message.senderName)
        }
        let addresses = Set(targets.map { $0.message.senderAddress.lowercased() })
        let affected = items.filter { addresses.contains($0.message.senderAddress.lowercased()) && $0.handled == nil }
        let rules = app.senderRules
        let covered = affected.filter { rules.action(for: $0.message) == action }
        switch action {
        case .important:
            update(affected.map(\.id)) {
                $0.isVIP = true
                if $0.category == .automated { $0.category = .fyi }
            }
        case .digest:
            update(affected.map(\.id)) { $0.category = .automated }
        case .keep:
            break
        case .markRead:
            setRead(covered, true)
        case .archive:
            move(covered, to: .archived)
        case .trash:
            move(covered, to: .deleted)
        case .junk:
            move(covered, to: .junked)
        }
        selection.subtract(targets.map(\.id))
    }

    /// Teaches the group for these senders; future triage files their mail there without asking the model.
    private func regroup(_ targets: [TriageItem], as category: TriageItem.Category) {
        for address in Set(targets.map(\.message.senderAddress)) {
            app.senderRules.setCategory(category.rawValue, for: address)
        }
        let addresses = Set(targets.map { $0.message.senderAddress.lowercased() })
        update(items.filter { addresses.contains($0.message.senderAddress.lowercased()) }.map(\.id)) {
            $0.category = category
            $0.learned = true
        }
        selection.subtract(targets.map(\.id))
    }

    private func reply(to item: TriageItem, intent: String) {
        guard let model = try? app.localMailModel() else {
            errors[item.id] = "Writing replies needs a local Chat model (Settings → Tasks → Chat)."
            return
        }
        let firstName = NSFullUserName().split(separator: " ").first.map(String.init)
        perform([item.id]) { source in
            let original = try await source.read(id: item.message.id).text
            let body = try await ReplyDrafter.draft(
                intent: intent, original: original, message: item.message, userName: firstName, provider: model.provider, model: model.model
            )
            _ = try await source.createDraft(to: [], subject: "", body: body, replyTo: item.message.id)
            update([item.id]) { $0.handled = .replied }
        }
    }

    // MARK: State

    private func perform(_ ids: [String], _ work: @escaping (any MailSource) async throws -> Void) {
        busy.formUnion(ids)
        for id in ids { errors[id] = nil }
        let source = app.mailSource
        Task {
            do {
                try await work(source)
            } catch {
                for id in ids { errors[id] = error.localizedDescription }
            }
            busy.subtract(ids)
        }
    }

    private func update(_ ids: [String], _ change: (inout TriageItem) -> Void) {
        guard !ids.isEmpty else { return }
        var attachments = message.attachments
        guard attachments.indices.contains(index), case .mailTriage(var stored) = attachments[index] else { return }
        for position in stored.indices where ids.contains(stored[position].id) { change(&stored[position]) }
        attachments[index] = .mailTriage(stored)
        message.attachments = attachments
        try? context.save()
    }
}

private struct TriageRow: View {
    let item: TriageItem
    let rule: SenderAction?
    @Binding var isSelected: Bool
    let busy: Bool
    let error: String?
    let onReply: (String) -> Void
    @State private var replying = false
    @State private var intent = ""

    private var unread: Bool { !item.message.isRead && item.handled == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Circle()
                .fill(unread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .help(unread ? "Unread" : "Read")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.message.senderName)
                        .fontWeight(unread ? .bold : .regular)
                        .foregroundStyle(unread ? .primary : .secondary)
                        .lineLimit(1)
                    if item.isVIP { badge("Important", Theme.accent) }
                    if let rule, rule != .important { badge("Rule: \(rule.title)", .secondary) }
                    if item.learned { badge("learned", .secondary) }
                    Text(item.message.date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Group {
                    if let url = item.message.url {
                        Link(item.message.subject, destination: url)
                    } else {
                        Text(item.message.subject)
                    }
                }
                .fontWeight(unread ? .semibold : .regular)
                .foregroundStyle(unread ? .primary : .secondary)
                .lineLimit(1)
                if let ask = item.ask, item.handled == nil {
                    Text(ask).font(.callout).foregroundStyle(Theme.accent)
                }
                if let handled = item.handled {
                    Text(outcome(handled)).font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.mini)
            } else if item.handled == nil {
                Button("Reply…", systemImage: "arrowshape.turn.up.left") { replying = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $replying, arrowEdge: .bottom) { replyForm }
                    .help("Reply… (right-click for all actions)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Theme.selection : Theme.field)
        .contentShape(.rect)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
    }

    private var replyForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reply to \(item.message.senderName)").font(.headline)
            TextField("What should it say? e.g. “yes, Thursday works, I'll bring the numbers”", text: $intent, axis: .vertical)
                .lineLimit(2...5)
                .onSubmit(send)
            Text("Your local model writes it in their language; it opens as a draft in Mail — you send it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { replying = false }
                Button("Write Draft", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(intent.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func send() {
        let text = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replying = false
        intent = ""
        onReply(text)
    }

    private func outcome(_ handled: TriageItem.Handled) -> String {
        switch handled {
        case .read: "Marked as read"
        case .archived: "Archived"
        case .deleted: "Deleted (in the trash)"
        case .junked: "In Junk"
        case .replied: "Reply draft opened in Mail"
        }
    }
}
