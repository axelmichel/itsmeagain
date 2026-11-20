import CompanionCore
import Foundation
import FoundationModels
import Routing

/// Apple's on-device foundation model (Apple Intelligence). Small (4K-token context) but private and instant.
public struct AppleOnDeviceProvider: LLMProvider {
    public static let modelID = "on-device"

    public let id: ProviderID = .appleIntelligence
    public let displayName = "Apple Intelligence"
    public var capabilities: ProviderCapabilities { [.streaming] }

    public init() {}

    /// `nil` when usable, otherwise why not.
    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off (System Settings → Apple Intelligence & Siri)."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        case .unavailable:
            return "The on-device model is unavailable."
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        if let reason = Self.unavailableReason { throw ProviderError.unavailable(reason) }
        return [ModelInfo(id: Self.modelID, displayName: "On-device model")]
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.unavailableReason { throw ProviderError.unavailable(reason) }
                    let session = LanguageModelSession(instructions: request.system)
                    var options = GenerationOptions()
                    options.temperature = request.options.temperature
                    options.maximumResponseTokens = request.options.maxTokens

                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: Self.prompt(for: request.messages), options: options) {
                        let content = snapshot.content
                        if content.hasPrefix(emitted) {
                            let delta = String(content.dropFirst(emitted.count))
                            if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                            emitted = content
                        }
                    }
                    continuation.yield(.done(nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The model's context is tiny, so earlier turns are condensed into the prompt, newest first, within budget.
    static func prompt(for messages: [ChatMessage], budget: Int = 6_000) -> String {
        guard let last = messages.last(where: { $0.role == .user }) else { return "" }
        let earlier = messages.dropLast(messages.count - (messages.lastIndex(of: last) ?? messages.count))
            .filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
        guard !earlier.isEmpty else { return last.content }

        var lines: [String] = []
        var used = last.content.count
        for message in earlier.reversed() {
            let line = "\(message.role == .user ? "User" : "Assistant"): \(message.content)"
            guard used + line.count <= budget else { break }
            lines.insert(line, at: 0)
            used += line.count
        }
        guard !lines.isEmpty else { return last.content }
        return "Conversation so far:\n\(lines.joined(separator: "\n"))\n\nUser: \(last.content)"
    }
}

/// Routes with the on-device model using guided generation; fast and needs no Ollama model loaded.
public struct AppleTaskClassifier: TaskClassifier {
    public init() {}

    public static var isAvailable: Bool { AppleOnDeviceProvider.unavailableReason == nil }

    @Generable
    enum Classification {
        case chat, translate, research, code
    }

    public func classify(_ text: String) async throws -> TaskKind {
        let session = LanguageModelSession(instructions: TaskRouter.classifierInstructions)
        let response = try await session.respond(to: String(text.prefix(2_000)), generating: Classification.self)
        switch response.content {
        case .chat: return .chat
        case .translate: return .translate
        case .research: return .research
        case .code: return .code
        }
    }
}
