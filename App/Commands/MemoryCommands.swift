import Commands
import Foundation
import Memory
import Persistence
import SwiftData

/// /remember, /forget, /memories, /whoami — the memory, straight from the user.
extension AppModel {
    static let memoryHandlers: Set<String> = ["remember", "forget", "memories", "whoami"]

    func runMemoryCommand(_ handler: String, input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        let argument = input.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        switch handler {
        case "remember" where argument.isEmpty: return .failed("Usage: /remember <fact> — e.g. /remember Anna is my sister")
        case "forget" where argument.isEmpty: return .failed("Usage: /forget <word> — shows matching memories to forget")
        default: break
        }
        var kind: MemoryKind?
        if handler == "memories", !argument.isEmpty {
            kind = MemoryKind.allCases.first { $0.rawValue.hasPrefix(argument.lowercased()) || $0.title.localizedCaseInsensitiveContains(argument) }
            guard kind != nil else { return .failed("Kinds: " + MemoryKind.allCases.map(\.rawValue).joined(separator: ", ")) }
        }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }

        if conversation.messages.isEmpty { conversation.title = text }
        conversation.append(role: .user, content: text, task: .chat)
        let reply = conversation.append(role: .assistant, content: "", task: .chat)
        try? context.save()
        let memory = memory

        chat.run(in: conversation, context: context) {
            switch handler {
            case "remember":
                do {
                    let (item, match) = try await memory.rememberFact(argument)
                    let note: String = switch match {
                    case .duplicate: "I already knew that."
                    case .update: "Updated what I knew."
                    case .new: "Remembered."
                    }
                    reply.content = "\(note) _\(item.kind.title)_"
                    reply.attachments = [.memories(title: "Remembered", ids: [item.id])]
                } catch {
                    reply.errorText = error.localizedDescription
                }
            case "forget":
                let matches = await memory.recall(argument)
                reply.content = matches.isEmpty
                    ? "Nothing remembered about “\(argument)”."
                    : "Choose what to forget:"
                if !matches.isEmpty { reply.attachments = [.memories(title: "About “\(argument)”", ids: matches.map(\.id))] }
            case "memories":
                let items = memory.book.active.filter { kind == nil || $0.kind == kind }
                let pending = memory.book.pending.count
                reply.content = items.isEmpty ? "_Nothing remembered yet. Tell me with /remember, or just chat — I learn from what you say._" : ""
                if pending > 0 { reply.content += (reply.content.isEmpty ? "" : "\n\n") + "\(pending) learned \(pending == 1 ? "item waits" : "items wait") for your review in the Memory tab." }
                reply.modelContent = items.map { "- [\($0.kind.rawValue)] \($0.text)" }.joined(separator: "\n")
                if !items.isEmpty { reply.attachments = [.memories(title: kind?.title ?? "What I know about you", ids: items.map(\.id))] }
            default:  // whoami
                let core = memory.book.coreProfile()
                if core.isEmpty {
                    reply.content = "_I don't know anything about you yet._"
                } else {
                    var lines = ["**What I use in every Chat answer**"]
                    for kind in MemoryKind.allCases {
                        let items = core.filter { $0.kind == kind }
                        guard !items.isEmpty else { continue }
                        lines.append("\n**\(kind.title)**")
                        lines += items.map { "- \($0.text)" }
                    }
                    let rest = memory.book.active.count - core.count
                    if rest > 0 { lines.append("\n_\(rest) more \(rest == 1 ? "memory is" : "memories are") used when relevant._") }
                    reply.content = lines.joined(separator: "\n")
                }
            }
        }
        return .handled
    }
}
