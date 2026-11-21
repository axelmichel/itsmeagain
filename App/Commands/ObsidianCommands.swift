import Commands
import Foundation
import Obsidian
import Persistence
import SwiftData

/// /note, /capture, /todos, /done, /find — straight to the vault, no model. Writes happen only
/// because the user typed the command.
extension AppModel {
    static let obsidianHandlers: Set<String> = ["note", "capture", "todos", "done", "find"]

    func runObsidianCommand(_ handler: String, input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        let vaults = vaults
        // "@cooking …" picks an enabled vault; otherwise the main vault.
        let (chosen, argument) = vaults.splitVaultPrefix(input.arguments.trimmingCharacters(in: .whitespacesAndNewlines))
        if input.arguments.hasPrefix("@"), chosen == nil {
            return .failed("No enabled vault “\(input.arguments.dropFirst().prefix { !$0.isWhitespace })”. Enabled: \(vaults.stores.map(\.vault.name).joined(separator: ", ")).")
        }
        guard let main = chosen ?? vaults.main else {
            return .failed("No Obsidian vault is enabled. Choose one in Settings → Assistant → Obsidian.")
        }
        switch handler {
        case "note" where argument.isEmpty: return .failed("Usage: /note [@vault] <text> — adds a line to today's daily note")
        case "capture" where argument.isEmpty: return .failed("Usage: /capture [@vault] <title> — <text>")
        case "done" where argument.isEmpty: return .failed("Usage: /done <words of the task>")
        case "find" where argument.isEmpty: return .failed("Usage: /find [@vault] <words>")
        default: break
        }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }

        if conversation.messages.isEmpty { conversation.title = text }
        conversation.append(role: .user, content: text, task: .chat)
        let reply = conversation.append(role: .assistant, content: "", task: .chat)
        try? context.save()

        chat.run(in: conversation, context: context) {
            do {
                switch handler {
                case "note":
                    let path = try main.appendToDailyNote(argument)
                    reply.content = "Added to [\(path)](\(main.vault.url(for: path)?.absoluteString ?? "")) in \(main.vault.name)."

                case "capture":
                    // "Title — text" or just text (title = first words).
                    let parts = argument.components(separatedBy: " — ")
                    let title = parts.count > 1 ? parts[0] : String(argument.split(separator: " ").prefix(6).joined(separator: " "))
                    let body = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : argument
                    let path = try main.createNote(title: title, text: body, frontmatter: ["created": Date.now.formatted(.iso8601.year().month().day())])
                    reply.content = "Saved [\(path)](\(main.vault.url(for: path)?.absoluteString ?? "")) in \(main.vault.name)."

                case "todos":
                    var stores = chosen.map { [$0] } ?? vaults.stores
                    var tasks: [VaultTask]
                    var title = chosen.map { "Open tasks in \($0.vault.name)" } ?? "Open tasks"
                    if let named = vaults.stores.first(where: { $0.vault.name.localizedCaseInsensitiveCompare(argument) == .orderedSame }) {
                        stores = [named]
                        title = "Open tasks in \(named.vault.name)"
                    }
                    tasks = stores.flatMap { $0.tasks() }
                    if argument.lowercased() == "due" {
                        tasks = tasks.filter { $0.isDue() }
                        title = "Due today or overdue"
                    } else if argument.hasPrefix("#") {
                        let tag = argument.dropFirst().lowercased()
                        tasks = tasks.filter { $0.tags.contains { $0.lowercased() == tag } }
                        title = "Open tasks tagged \(argument)"
                    }
                    reply.content = tasks.isEmpty ? "_No \(title.lowercased())._" : ""
                    if !tasks.isEmpty { reply.attachments = [.vaultTasks(title: "\(title) (\(tasks.count))", tasks: Array(tasks.prefix(80)))] }

                case "done":
                    let words = argument.lowercased().split(separator: " ")
                    let matches = (chosen.map { [$0] } ?? vaults.stores).flatMap { $0.tasks() }.filter { task in
                        words.allSatisfy { task.text.lowercased().contains($0) }
                    }
                    reply.content = matches.isEmpty ? "No open task matches “\(argument)”." : "Tick the one you mean:"
                    if !matches.isEmpty { reply.attachments = [.vaultTasks(title: "Matching tasks", tasks: Array(matches.prefix(20)))] }

                default:  // find: by meaning (when indexed) and words
                    let stores = chosen.map { [$0] } ?? vaults.stores
                    var lines: [String] = []
                    for hit in await vaults.search(argument, in: stores, limit: 12) {
                        let link = stores.first { $0.vault.name == hit.vault }?.vault.url(for: hit.path)?.absoluteString ?? ""
                        let vaultLabel = stores.count > 1 ? " · _\(hit.vault)_" : ""
                        lines.append("- [\(hit.path)](\(link))\(vaultLabel)\n  \(hit.snippet)")
                    }
                    reply.content = lines.isEmpty ? "No notes match “\(argument)”." : lines.joined(separator: "\n")
                }
            } catch {
                reply.errorText = error.localizedDescription
            }
        }
        return .handled
    }
}
