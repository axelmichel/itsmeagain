import Commands
import Foundation
import Mail
import Persistence
import SwiftData

/// `/inbox`: unread mail of the last two days, grouped by account — straight from Mail, no model.
/// Subjects link to the message in Mail (message:// URLs).
extension AppModel {
    func runInboxCommand(input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        guard mailEnabled else { return .failed("Mail is turned off in Settings → Assistant.") }
        if conversation.messages.isEmpty { conversation.title = text }
        conversation.append(role: .user, content: text, task: .chat)
        let reply = conversation.append(role: .assistant, content: "", task: .chat)
        try? context.save()

        let account = input.arguments.isEmpty ? nil : input.arguments
        let preferences = mailPreferences
        let source = mailSource
        chat.run(in: conversation, context: context) {
            do {
                var messages = try await source.recent(days: 2, unreadOnly: true, limit: 80).filter(preferences.includes)
                if let account { messages = messages.filter { $0.account.localizedCaseInsensitiveContains(account) } }
                reply.content = Self.inboxMarkdown(messages, preferences: preferences)
            } catch {
                reply.errorText = error.localizedDescription
            }
        }
        return .handled
    }

    /// `/cleanup`: junk rules run right away; new mailing-list senders get the model's suggestion and
    /// buttons to decide. Nothing moves on a suggestion alone.
    func runCleanupCommand(text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        guard mailEnabled else { return .failed("Mail is turned off in Settings → Assistant.") }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        let reply = start(text, in: conversation, context: context, status: "_Reading mailing-list mail…_")
        let (source, rules, preferences, topics) = (mailSource, senderRules, mailPreferences, newsletterTopicList)
        let model = try? localMailModel()
        chat.run(in: conversation, context: context) {
            do {
                let result = try await MailCleanup.run(source: source, rules: rules, preferences: preferences, topics: topics, model: model)
                reply.content = MailCleanup.summary(result) + (model == nil ? "\n\n_No local Chat model, so no suggestions._" : "")
                if !result.groups.isEmpty { reply.attachments = [.mailCleanup(groups: result.groups)] }
            } catch {
                reply.content = ""
                reply.errorText = error.localizedDescription
            }
        }
        return .handled
    }

    /// `/digest [days]`: topic items from digest senders' unread newsletters, which are then marked
    /// read and archived.
    func runDigestCommand(input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        guard mailEnabled else { return .failed("Mail is turned off in Settings → Assistant.") }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        let days = input.positional.first.flatMap(Int.init).map { min(max($0, 1), 30) } ?? 7
        let model: MailModel
        do { model = try localMailModel() } catch { return .failed(error.localizedDescription) }
        guard senderRules.rules.contains(where: { $0.action == .digest }) else {
            return .failed("No digest senders yet. Run /cleanup and mark newsletters you like as Digest.")
        }
        let reply = start(text, in: conversation, context: context, status: "_Looking for newsletters…_")
        let (source, rules, preferences, topics) = (mailSource, senderRules, mailPreferences, newsletterTopicList)
        chat.run(in: conversation, context: context) {
            do {
                let result = try await NewsletterDigest.run(
                    source: source, rules: rules, preferences: preferences, topics: topics, model: model, days: days, archive: true
                ) { done, total in
                    if total > 0 { reply.content = "_Reading newsletters… \(done) of \(total)_" }
                }
                reply.content = NewsletterDigest.markdown(result, topics: topics)
            } catch {
                reply.content = ""
                reply.errorText = error.localizedDescription
            }
        }
        return .handled
    }

    /// `/appointments [days]`: appointments in unread mail (default: last 14 days), each with your
    /// free/conflict status and Add / Ignore.
    func runAppointmentsCommand(input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        guard mailEnabled else { return .failed("Mail is turned off in Settings → Assistant.") }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        guard let watcher = mailWatcher else { return .failed("Mail isn't ready yet.") }
        let days = input.positional.first.flatMap(Int.init).map { min(max($0, 1), 60) } ?? 14
        let reply = start(text, in: conversation, context: context, status: "_Reading unread mail…_")
        chat.run(in: conversation, context: context) {
            do {
                let found = try await watcher.findAppointments(days: days) { done, total in
                    reply.content = "_Reading unread mail… \(done) of \(total)_"
                }
                reply.content = found.isEmpty
                    ? "No appointments in your unread mail of the last \(days) days."
                    : "**\(found.count) \(found.count == 1 ? "appointment" : "appointments")** in your unread mail of the last \(days) days:"
                if !found.isEmpty { reply.attachments = [.appointments(found)] }
            } catch {
                reply.content = ""
                reply.errorText = error.localizedDescription
            }
        }
        return .handled
    }

    /// `/watched`: unread mail from important senders of the last seven days, grouped by address.
    func runWatchedCommand(text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        guard mailEnabled else { return .failed("Mail is turned off in Settings → Assistant.") }
        let preferences = mailPreferences
        guard !preferences.vipSenders.isEmpty else {
            return .failed("Add important senders first: Settings → Assistant → Mail → Important senders.")
        }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        let reply = start(text, in: conversation, context: context, status: "_Checking mail…_")
        let source = mailSource
        chat.run(in: conversation, context: context) {
            do {
                let messages = try await source.recent(days: 7, unreadOnly: true, limit: 200).filter(preferences.includes)
                let groups = MailWatch.fromImportant(messages, preferences: preferences, seen: [])
                if groups.isEmpty {
                    reply.content = "No unread mail from your important senders in the last seven days."
                } else {
                    reply.content = groups.map { group in
                        "**\(group.messages[0].senderName)** · \(group.address) (\(group.messages.count))\n"
                            + group.messages.map { MailFormatter.line($0, preferences: preferences, markdown: true) }.joined(separator: "\n")
                    }.joined(separator: "\n\n")
                }
            } catch {
                reply.content = ""
                reply.errorText = error.localizedDescription
            }
        }
        return .handled
    }

    private func start(_ text: String, in conversation: Conversation, context: ModelContext, status: String) -> StoredMessage {
        if conversation.messages.isEmpty { conversation.title = text }
        conversation.append(role: .user, content: text, task: .chat)
        let reply = conversation.append(role: .assistant, content: status, task: .chat)
        try? context.save()
        return reply
    }

    static func inboxMarkdown(_ messages: [MailMessage], preferences: MailPreferences) -> String {
        guard !messages.isEmpty else { return "_No unread mail in the last two days._" }
        let automated = messages.filter { preferences.kind(of: $0) == .newsletter }
        let personal = messages.filter { preferences.kind(of: $0) != .newsletter }
        var sections: [String] = []
        let vip = personal.filter { preferences.kind(of: $0) == .vip }
        if !vip.isEmpty {
            sections.append("**Important**\n" + vip.map { MailFormatter.line($0, preferences: preferences, markdown: true) }.joined(separator: "\n"))
        }
        let byAccount = Dictionary(grouping: personal.filter { preferences.kind(of: $0) != .vip }, by: \.account)
        for account in byAccount.keys.sorted() {
            let lines = byAccount[account]!.map { MailFormatter.line($0, preferences: preferences, markdown: true) }
            sections.append("**\(account)** (\(lines.count))\n" + lines.joined(separator: "\n"))
        }
        if !automated.isEmpty {
            let senders = Set(automated.map(\.senderName)).sorted().prefix(6).joined(separator: ", ")
            sections.append("_\(automated.count) automated (\(senders)\(automated.count > 6 ? ", …" : ""))_")
        }
        return sections.joined(separator: "\n\n") + "\n\n_Click a subject to open it in Mail. /triage sorts it for you._"
    }
}
