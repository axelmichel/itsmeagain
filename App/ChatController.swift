import CompanionCore
import Foundation
import Observation
import Persistence
import Routing
import SwiftData
import Tools

/// Everything a turn needs once its task is known.
struct TurnPlan {
    var provider: any LLMProvider
    var profile: TaskProfile
    var model: String
    var targetLanguage: String
    var tools: [any Tool]
    var policy: ToolPolicy
    /// Runs after a successful reply (e.g. /brief attaches the due reminders).
    var finalize: (@MainActor (StoredMessage) async -> Void)?
}

/// Runs model turns for conversations. Streams keep running when the user switches conversations.
/// Messages sent while a reply is running wait in a per-conversation queue (in memory only).
@MainActor
@Observable
final class ChatController {
    typealias Planner = @MainActor () async throws -> TurnPlan

    struct QueuedMessage: Identifiable {
        let id = UUID()
        var text: String
        fileprivate let modelText: String?
        fileprivate let context: ModelContext
        fileprivate let plan: Planner
    }

    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    private var queues: [PersistentIdentifier: [QueuedMessage]] = [:]
    /// Stopping a reply pauses its conversation's queue until the user resumes or sends again.
    private var paused: Set<PersistentIdentifier> = []

    func isStreaming(_ conversation: Conversation) -> Bool {
        tasks[conversation.persistentModelID] != nil
    }

    func queue(for conversation: Conversation) -> [QueuedMessage] {
        queues[conversation.persistentModelID] ?? []
    }

    func isQueuePaused(_ conversation: Conversation) -> Bool {
        paused.contains(conversation.persistentModelID)
    }

    /// Sends now, or queues behind the running reply (and anything already queued).
    /// `modelText` replaces `text` for the model (e.g. an expanded command); the transcript shows `text`.
    func send(_ text: String, modelText: String? = nil, in conversation: Conversation, context: ModelContext, plan: @escaping Planner) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let key = conversation.persistentModelID
        if isStreaming(conversation) || !(queues[key] ?? []).isEmpty {
            queues[key, default: []].append(QueuedMessage(text: text, modelText: modelText, context: context, plan: plan))
            // Sending while paused means "carry on".
            if !isStreaming(conversation) { resume(conversation) }
            return
        }
        start(text, modelText: modelText, in: conversation, context: context, plan: plan)
    }

    /// Runs a native command's work (no model turn) as the conversation's running task, so Stop,
    /// the progress indicator and automations treat it like a reply. Returns false while busy.
    @discardableResult
    func run(in conversation: Conversation, context: ModelContext, _ work: @escaping @MainActor () async -> Void) -> Bool {
        guard !isStreaming(conversation) else { return false }
        let key = conversation.persistentModelID
        tasks[key] = Task {
            await work()
            conversation.updatedAt = .now
            try? context.save()
            tasks[key] = nil
            startNext(in: conversation)
        }
        return true
    }

    func resume(_ conversation: Conversation) {
        paused.remove(conversation.persistentModelID)
        startNext(in: conversation)
    }

    func removeQueued(_ id: QueuedMessage.ID, from conversation: Conversation) {
        queues[conversation.persistentModelID]?.removeAll { $0.id == id }
    }

    /// Stops everything for a conversation that is going away.
    func discard(_ conversation: Conversation) {
        let key = conversation.persistentModelID
        queues[key] = nil
        paused.remove(key)
        tasks[key]?.cancel()
    }

    private func startNext(in conversation: Conversation) {
        let key = conversation.persistentModelID
        guard !isStreaming(conversation), !paused.contains(key), let next = queues[key]?.first else { return }
        queues[key]?.removeFirst()
        start(next.text, modelText: next.modelText, in: conversation, context: next.context, plan: next.plan)
    }

    /// Appends the user message right away; `plan` (which may route the message first) runs before streaming.
    private func start(_ text: String, modelText: String?, in conversation: Conversation, context: ModelContext, plan: @escaping Planner) {
        if conversation.messages.isEmpty {
            conversation.title = Self.title(for: text)
        }
        let prompt = conversation.append(role: .user, content: text)
        prompt.modelContent = modelText
        let reply = conversation.append(role: .assistant, content: "")
        try? context.save()

        let key = conversation.persistentModelID
        tasks[key] = Task {
            var cancelled = false
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
                let loop = ToolLoop(provider: plan.provider, tools: plan.tools, policy: plan.policy)
                for try await event in loop.run(request) {
                    switch event {
                    case .text(let delta):
                        reply.content += delta
                    case .thinking(let delta):
                        reply.thinking += delta
                    case .roundStarted:
                        // Keep text from separate rounds ("Let me search…" / the answer) apart.
                        if !reply.content.isEmpty && !reply.content.hasSuffix("\n\n") { reply.content += "\n\n" }
                    case .toolStarted(let call):
                        reply.toolSteps.append(ToolStep(id: call.id, tool: call.name, subject: Self.subject(of: call)))
                    case .approvalRequested(let request):
                        updateStep(request.id, in: reply) {
                            $0.status = .awaitingApproval
                            $0.approvalSummary = request.summary
                        }
                    case .approvalResolved(let id, let granted):
                        if granted { updateStep(id, in: reply) { $0.status = .running } }
                    case .toolFinished(let id, let output, let error):
                        var steps = reply.toolSteps
                        if let index = steps.firstIndex(where: { $0.id == id && ($0.status == .running || $0.status == .awaitingApproval) }) {
                            steps[index].status = error == nil ? .done : .failed
                            steps[index].error = error
                            steps[index].sources = output?.sources ?? []
                            reply.toolSteps = steps
                        }
                    }
                }
                if let finalize = plan.finalize, reply.errorText == nil { await finalize(reply) }
            } catch is CancellationError {
                cancelled = true
            } catch let error as URLError where error.code == .cancelled {
                cancelled = true
            } catch {
                reply.errorText = error.localizedDescription
            }
            // A cancelled turn can leave steps that never finished.
            if reply.toolSteps.contains(where: { $0.status == .running || $0.status == .awaitingApproval }) {
                reply.toolSteps = reply.toolSteps.map { step in
                    var step = step
                    if step.status == .running || step.status == .awaitingApproval { step.status = .failed; step.error = "Stopped" }
                    return step
                }
            }
            conversation.updatedAt = .now
            try? context.save()
            tasks[key] = nil
            if cancelled || Task.isCancelled {
                if !(queues[key] ?? []).isEmpty { paused.insert(key) }
            } else {
                startNext(in: conversation)
            }
        }
    }

    func stop(_ conversation: Conversation) {
        tasks[conversation.persistentModelID]?.cancel()
    }

    private func updateStep(_ id: String, in message: StoredMessage, _ change: (inout ToolStep) -> Void) {
        var steps = message.toolSteps
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        change(&steps[index])
        message.toolSteps = steps
    }

    private static func subject(of call: ToolCall) -> String {
        call.arguments["query"]?.stringValue ?? call.arguments["url"]?.stringValue ?? call.arguments.jsonString
    }

    private static func title(for text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }
}
