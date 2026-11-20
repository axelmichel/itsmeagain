import CompanionCore
import Foundation
import Observation
import Persistence
import Routing
import SwiftData

/// Everything a turn needs once its task is known.
struct TurnPlan {
    var provider: any LLMProvider
    var profile: TaskProfile
    var model: String
    var targetLanguage: String
}

/// Runs model turns for conversations. Streams keep running when the user switches conversations.
@MainActor
@Observable
final class ChatController {
    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]

    func isStreaming(_ conversation: Conversation) -> Bool {
        tasks[conversation.persistentModelID] != nil
    }

    /// Appends the user message right away; `plan` (which may route the message first) runs before streaming.
    func send(
        _ text: String,
        in conversation: Conversation,
        context: ModelContext,
        plan: @escaping @MainActor () async throws -> TurnPlan
    ) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming(conversation) else { return }

        if conversation.messages.isEmpty {
            conversation.title = Self.title(for: text)
        }
        let prompt = conversation.append(role: .user, content: text)
        let reply = conversation.append(role: .assistant, content: "")
        try? context.save()

        let key = conversation.persistentModelID
        tasks[key] = Task {
            do {
                let plan = try await plan()
                prompt.taskRaw = plan.profile.task.rawValue
                reply.taskRaw = plan.profile.task.rawValue
                reply.modelID = plan.model
                let request = plan.profile.makeRequest(
                    history: conversation.chatMessages,
                    model: plan.model,
                    targetLanguage: plan.targetLanguage
                )
                for try await event in plan.provider.stream(request) {
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
