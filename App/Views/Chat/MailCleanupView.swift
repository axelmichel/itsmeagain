import AppKit
import Mail
import Persistence
import SwiftData
import SwiftUI

/// Mailing-list senders from /cleanup. A choice saves a rule that runs automatically from then on;
/// Junk moves the mail right away. These are the user's own clicks, so no approval card.
struct MailCleanupView: View {
    let message: StoredMessage
    let index: Int
    let groups: [SenderGroup]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    /// What's happening per sender ("Moving to Junk…"); moves wait for each other in Mail.
    @State private var status: [String: String] = [:]
    @State private var errors: [String: String] = [:]
    @State private var pendingUnsubscribe: SenderGroup?

    private var suggested: [SenderGroup] {
        groups.filter { $0.rule == nil && $0.outcome == nil && $0.suggestion != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mailing lists").font(.callout.weight(.semibold))
                Spacer()
                if !suggested.isEmpty {
                    Button("Apply \(suggested.count) Suggestions", action: applySuggestions)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(!status.isEmpty)
                        .help("Save every suggestion as a rule; suggested Junk moves to Junk now")
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(groups) { group in
                    SenderRow(
                        group: group,
                        status: status[group.address],
                        error: errors[group.address],
                        onDecide: { decide(group, $0, wholeDomain: $1) },
                        onArchive: { archive(group) },
                        onUnsubscribe: { pendingUnsubscribe = group },
                        onUndo: { undo(group) }
                    )
                }
            }
        }
        .confirmationDialog(
            "Unsubscribe from \(pendingUnsubscribe?.name ?? "")?",
            isPresented: Binding(get: { pendingUnsubscribe != nil }, set: { if !$0 { pendingUnsubscribe = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unsubscribe") {
                guard let group = pendingUnsubscribe else { return }
                unsubscribe(group)
            }
        } message: {
            Text(unsubscribeExplanation(pendingUnsubscribe))
        }
    }

    // MARK: Actions

    private func decide(_ group: SenderGroup, _ action: SenderAction, wholeDomain: Bool) {
        let key = wholeDomain ? group.domain : group.address
        app.senderRules.set(key, action, name: group.name)
        let scope = wholeDomain ? "mailing-list mail from \(group.domain)" : "this sender"
        switch action {
        case .junk:
            // Only what the rule covers: order, invoice and account mail stays in the inbox.
            let covered = group.messages.filter { app.senderRules.action(for: $0) == .junk }
            let spared = group.messages.count - covered.count
            let note = spared > 0 ? " · kept \(spared) order/account mail" : ""
            guard !covered.isEmpty else {
                store(update(group) {
                    $0.rule = .junk
                    $0.outcome = "Rule saved · nothing to move\(note)"
                })
                return
            }
            perform(group, "Moving \(covered.count) to Junk…") { source in
                let moved = try await source.move(ids: covered.map(\.id), to: .junk, markRead: true)
                if moved == 0 { throw MailError.script("Mail no longer has these messages in the inbox.") }
                return update(group) {
                    $0.rule = .junk
                    $0.outcome = "Moved \(moved) to Junk\(note) · \(scope) goes to Junk from now on"
                    $0.movedTo = .junk
                }
            }
        case .digest:
            store(update(group) {
                $0.rule = .digest
                $0.outcome = "Digest · /digest summarises \(scope), then archives it"
            })
        case .keep:
            store(update(group) {
                $0.rule = .keep
                $0.outcome = "Kept · won't ask about \(scope) again"
            })
        }
    }

    private func archive(_ group: SenderGroup) {
        perform(group, "Archiving…") { source in
            let moved = try await source.move(ids: group.messages.map(\.id), to: .archive, markRead: true)
            return update(group) {
                $0.outcome = "Archived \(moved)"
                $0.movedTo = .archive
            }
        }
    }

    private func undo(_ group: SenderGroup) {
        // Back to undecided: drop whichever rule matched this sender (its own, else the domain's).
        app.senderRules.remove(group.address)
        if app.senderRules.action(for: group.address) != nil { app.senderRules.remove(group.domain) }
        perform(group, "Undoing…") { source in
            if let folder = group.movedTo {
                _ = try await source.move(ids: group.messages.map(\.id), to: .inbox, markRead: false, from: folder)
                let unread = group.messages.filter { !$0.isRead }.map(\.id)
                if !unread.isEmpty { _ = try await source.markRead(ids: unread, false) }
            }
            return update(group) {
                $0.outcome = nil
                $0.movedTo = nil
                $0.rule = nil
            }
        }
    }

    private func applySuggestions() {
        for group in suggested {
            guard let action = group.suggestion else { continue }
            decide(group, action, wholeDomain: false)
        }
    }

    private func unsubscribe(_ group: SenderGroup) {
        guard let method = UnsubscribeMethod.best(for: group.bulk) else { return }
        switch method {
        case .oneClick(let url):
            perform(group, "Unsubscribing…") { _ in
                try await Unsubscriber.oneClick(url)
                return update(group) { $0.outcome = "Unsubscribed" + ($0.outcome.map { " · \($0)" } ?? "") }
            }
        case .openPage(let url):
            NSWorkspace.shared.open(url)
            store(update(group) { $0.outcome = "Unsubscribe page opened in your browser" })
        case .mailto(let address, let subject):
            perform(group, "Opening Mail…") { source in
                _ = try await source.createDraft(to: [address], subject: subject, body: "unsubscribe", replyTo: nil)
                return update(group) { $0.outcome = "Unsubscribe mail opened in Mail — send it to finish" }
            }
        }
    }

    private func unsubscribeExplanation(_ group: SenderGroup?) -> String {
        guard let group, let method = UnsubscribeMethod.best(for: group.bulk) else { return "" }
        switch method {
        case .oneClick(let url): return "Sends the list's one-click unsubscribe request to \(url.host() ?? "the sender")."
        case .openPage(let url): return "Opens \(url.host() ?? "the unsubscribe page") in your browser."
        case .mailto(let address, _): return "Opens an unsubscribe mail to \(address) in Mail; you send it."
        }
    }

    // MARK: State

    private func perform(_ group: SenderGroup, _ label: String, _ action: @escaping (any MailSource) async throws -> [SenderGroup]) {
        status[group.address] = label
        errors[group.address] = nil
        let source = app.mailSource
        Task {
            do {
                store(try await action(source))
            } catch {
                // The rule (if any) is already saved; the next /cleanup applies it again.
                let rule = app.senderRules.action(for: group.address) == .junk ? " Your Junk rule is saved and runs on the next /cleanup." : ""
                errors[group.address] = error.localizedDescription + rule
            }
            status[group.address] = nil
        }
    }

    /// The current groups with one changed (reads the stored state, so overlapping actions don't clobber each other).
    private func update(_ group: SenderGroup, _ change: (inout SenderGroup) -> Void) -> [SenderGroup] {
        var current = groups
        if message.attachments.indices.contains(index), case .mailCleanup(let stored) = message.attachments[index] { current = stored }
        guard let position = current.firstIndex(where: { $0.address == group.address }) else { return current }
        change(&current[position])
        return current
    }

    private func store(_ updated: [SenderGroup]) {
        var attachments = message.attachments
        guard attachments.indices.contains(index) else { return }
        attachments[index] = .mailCleanup(groups: updated)
        message.attachments = attachments
        try? context.save()
    }
}

private struct SenderRow: View {
    let group: SenderGroup
    let status: String?
    let error: String?
    let onDecide: (SenderAction, _ wholeDomain: Bool) -> Void
    let onArchive: () -> Void
    let onUnsubscribe: () -> Void
    let onUndo: () -> Void
    @State private var hovered = false

    /// Never offer to unsubscribe from spam: it only confirms the address is read.
    private var canUnsubscribe: Bool {
        group.bulk.canUnsubscribe && group.rule != .junk && group.suggestion != .junk
            && UnsubscribeMethod.best(for: group.bulk) != nil && group.outcome?.hasPrefix("Unsubscribe") != true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name).lineLimit(1)
                    Text("\(group.messages.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let suggestion = group.suggestion, group.rule == nil, group.outcome == nil {
                        Text("Suggested: \(suggestion.title)")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(status ?? group.outcome ?? group.reason.map { "\(group.address) · \($0)" } ?? group.address)
                    .font(.caption)
                    .foregroundStyle(status != nil ? Theme.accent : .secondary)
                    .lineLimit(1)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                } else if group.outcome == nil, status == nil {
                    Text(group.messages.prefix(2).map(\.subject).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if status != nil {
                ProgressView().controlSize(.mini)
            } else if group.outcome != nil {
                Button("Undo", action: onUndo)
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else {
                HStack(spacing: 10) {
                    decision(.junk)
                    decision(.digest)
                    decision(.keep)
                    Menu {
                        Button("Archive \(group.messages.count) Messages", action: onArchive)
                        if canUnsubscribe {
                            Button("Unsubscribe…", action: onUnsubscribe)
                        }
                        Divider()
                        ForEach(SenderAction.allCases, id: \.self) { action in
                            Button("\(action.title) All Mailing Lists from \(group.domain)") { onDecide(action, true) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovered ? Theme.hover : Theme.field)
        .onHover { hovered = $0 }
    }

    private func decision(_ action: SenderAction) -> some View {
        Button(action.title) { onDecide(action, false) }
            .buttonStyle(.borderless)
            .fontWeight(group.suggestion == action ? .semibold : .regular)
            .help(help(action))
    }

    private func help(_ action: SenderAction) -> String {
        switch action {
        case .junk: "Move to Junk now and from now on (order and account mail is never junked)"
        case .digest: "Summarise in /digest, then archive"
        case .keep: "Leave in the inbox and don't ask again"
        }
    }
}

extension SenderGroup {
    var domain: String {
        address.lastIndex(of: "@").map { String(address[$0...]) } ?? address
    }
}
