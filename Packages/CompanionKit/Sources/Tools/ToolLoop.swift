import CompanionCore
import Foundation

public enum AgentEvent: Sendable, Hashable {
    case text(String)
    case thinking(String)
    case toolStarted(ToolCall)
    case toolFinished(id: String, output: ToolOutput?, error: String?)
    /// A write tool waits for the user (`ToolPolicy.approve`).
    case approvalRequested(ApprovalRequest)
    case approvalResolved(id: String, granted: Bool)
    /// A new model round starts after tool results (UI separates the text of consecutive rounds).
    case roundStarted
}

/// Runs a request, executes the tools the model calls, feeds results back, and repeats until
/// the model answers without calling tools (or `maxRounds` is reached).
///
/// The `ToolPolicy` is enforced here, independent of the model:
/// - private tools are neither offered to nor executable by non-local providers,
/// - write tools need approval unless auto-approved,
/// - after any private data was read, tools that send data out (`sendsDataExternally`) are
///   withdrawn for the rest of the turn.
public struct ToolLoop: Sendable {
    public let provider: any LLMProvider
    public let tools: [any Tool]
    public let policy: ToolPolicy
    public var maxRounds: Int
    public var toolTimeout: Duration

    public init(
        provider: any LLMProvider,
        tools: [any Tool],
        policy: ToolPolicy = .strict,
        maxRounds: Int = 8,
        toolTimeout: Duration = .seconds(45)
    ) {
        self.provider = provider
        self.tools = tools
        self.policy = policy
        self.maxRounds = maxRounds
        self.toolTimeout = toolTimeout
    }

    public func run(_ request: ChatRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await loop(request, continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Tools this provider may see at all.
    var permittedTools: [any Tool] {
        tools.filter { policy.providerIsLocal || $0.dataClass == .public }
    }

    private func loop(_ initial: ChatRequest, _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async throws {
        var request = initial
        let permitted = permittedTools
        let useTools = provider.capabilities.contains(.tools) && !permitted.isEmpty
        var readPrivateData = false

        var previousCalls: Set<String> = []
        for round in 0..<maxRounds {
            if round > 0 { continuation.yield(.roundStarted) }
            let offered = permitted.filter { !(readPrivateData && $0.sendsDataExternally) }
            request.tools = useTools ? offered.map(\.spec) : []

            var text = ""
            var calls: [ToolCall] = []
            var raw: JSONValue?
            for try await event in provider.stream(request) {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    continuation.yield(.text(delta))
                case .thinkingDelta(let delta):
                    continuation.yield(.thinking(delta))
                case .toolCall(let call):
                    calls.append(call)
                case .assistantContent(let content):
                    raw = content
                case .done:
                    break
                }
            }
            guard useTools, !calls.isEmpty else { return }

            request.messages.append(ChatMessage(role: .assistant, content: text, toolCalls: calls, providerContent: raw))
            for call in calls { continuation.yield(.toolStarted(call)) }
            // Small models sometimes repeat a call verbatim; answer from memory instead of re-running it.
            let repeated = calls.map { !previousCalls.insert("\($0.name) \($0.arguments.jsonString)").inserted }
            let fresh = await execute(zip(calls, repeated).filter { !$1 }.map(\.0), offered: offered, continuation)
            var freshResults = fresh.makeIterator()
            let results: [Result<ToolOutput, Error>] = repeated.map { isRepeat in
                isRepeat
                    ? .failure(ToolError.failed("You already made this exact call; its result is above. Change the arguments, fetch a result page, or answer."))
                    : freshResults.next()!
            }
            let byName = Dictionary(offered.map { ($0.spec.name, $0) }, uniquingKeysWith: { first, _ in first })
            for (call, result) in zip(calls, results) {
                switch result {
                case .success(let output):
                    if byName[call.name]?.dataClass == .private { readPrivateData = true }
                    continuation.yield(.toolFinished(id: call.id, output: output, error: nil))
                    request.messages.append(ChatMessage(role: .tool, content: output.content, toolCallID: call.id, toolName: call.name))
                case .failure(let error):
                    let message = error.localizedDescription
                    continuation.yield(.toolFinished(id: call.id, output: nil, error: message))
                    request.messages.append(ChatMessage(role: .tool, content: "Error: \(message)", toolCallID: call.id, toolName: call.name))
                }
            }
        }
        continuation.yield(.text("\n\n_Stopped after \(maxRounds) rounds of tool use._"))
    }

    /// Runs all calls of a round concurrently; results keep the calls' order.
    private func execute(
        _ calls: [ToolCall],
        offered: [any Tool],
        _ continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async -> [Result<ToolOutput, Error>] {
        let byName = Dictionary(offered.map { ($0.spec.name, $0) }, uniquingKeysWith: { first, _ in first })
        let allNames = Set(tools.map(\.spec.name))
        let policy = policy
        let timeout = toolTimeout
        return await withTaskGroup(of: (Int, Result<ToolOutput, Error>).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    guard let tool = byName[call.name] else {
                        // Known but withheld (private data for a remote model, or locked after a private read).
                        let reason = allNames.contains(call.name)
                            ? "“\(call.name)” isn't available right now."
                            : "Unknown tool “\(call.name)”."
                        return (index, .failure(ToolError.failed(reason)))
                    }
                    if tool.effect == .write && !policy.autoApproved.contains(tool.spec.name) {
                        let request = ApprovalRequest(
                            id: call.id, toolName: call.name, summary: tool.describe(call.arguments), arguments: call.arguments
                        )
                        continuation.yield(.approvalRequested(request))
                        let granted = await policy.approve(request)
                        continuation.yield(.approvalResolved(id: call.id, granted: granted))
                        guard granted else {
                            return (index, .failure(ToolError.failed("The user declined: \(request.summary)")))
                        }
                    }
                    return (index, await Self.run(tool, call.arguments, timeout: timeout))
                }
            }
            var results = [Result<ToolOutput, Error>?](repeating: nil, count: calls.count)
            for await (index, result) in group { results[index] = result }
            return results.map { $0! }
        }
    }

    private static func run(_ tool: any Tool, _ arguments: JSONValue, timeout: Duration) async -> Result<ToolOutput, Error> {
        await withTaskGroup(of: Result<ToolOutput, Error>?.self) { group in
            group.addTask {
                do { return .success(try await tool.run(arguments)) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(ToolError.failed("\(tool.spec.name) timed out."))
        }
    }
}
