import CompanionCore
import Foundation
import Observation
import Persistence
import SwiftData

/// Runs model turns for conversations. Streams keep running when the user switches conversations.
@MainActor
@Observable
final class ChatController {
    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]

    func isStreaming(_ conversation: Conversation) -> Bool {
        tasks[conversation.persistentModelID] != nil
    }

    func send(_ text: String, in conversation: Conversation, using provider: any LLMProvider, context: ModelContext) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming(conversation) else { return }

        if conversation.messages.isEmpty {
            conversation.title = Self.title(for: text)
        }
        conversation.append(role: .user, content: text)
        let request = ChatRequest(
            model: conversation.modelID,
            messages: conversation.chatMessages,
            options: ChatOptions(keepAlive: "10m")
        )
        let reply = conversation.append(role: .assistant, content: "", modelID: conversation.modelID)
        try? context.save()

        let key = conversation.persistentModelID
        tasks[key] = Task {
            do {
                for try await event in provider.stream(request) {
                    switch event {
                    case .textDelta(let delta): reply.content += delta
                    case .thinkingDelta(let delta): reply.thinking += delta
                    case .toolCall, .done: break
                    }
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                reply.errorText = error.localizedDescription
            }
            conversation.updatedAt = .now
            try? context.save()
            tasks[key] = nil
        }
    }

    func stop(_ conversation: Conversation) {
        tasks[conversation.persistentModelID]?.cancel()
    }

    private static func title(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }
}
