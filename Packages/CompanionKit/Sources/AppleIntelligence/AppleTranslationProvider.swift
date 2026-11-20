import CompanionCore
import Foundation
import NaturalLanguage
import Routing
import Translation

/// macOS' built-in translation (the Translate app's models). Fully on-device once languages are downloaded.
/// It only translates: it reads the last user message and `ChatRequest.targetLanguage`, ignoring prompts.
public struct AppleTranslationProvider: LLMProvider {
    public static let modelID = "system"

    public let id: ProviderID = .appleTranslation
    public let displayName = "Apple Translation"
    public var capabilities: ProviderCapabilities { [.streaming] }

    public init() {}

    public func listModels() async throws -> [ModelInfo] {
        guard #available(macOS 26.4, *) else {
            throw ProviderError.unavailable("Apple Translation needs macOS 26.4 or later.")
        }
        return [ModelInfo(id: Self.modelID, displayName: "System translation")]
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = request.messages.last(where: { $0.role == .user })?.content ?? ""
                    let translated = try await Self.translate(text, into: request.targetLanguage ?? "English")
                    continuation.yield(.textDelta(translated))
                    continuation.yield(.done(nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func translate(_ text: String, into targetName: String) async throws -> String {
        guard #available(macOS 26.4, *) else {
            throw ProviderError.unavailable("Apple Translation needs macOS 26.4 or later.")
        }
        guard let code = Languages.code(for: targetName) else {
            throw ProviderError.unavailable("Apple Translation doesn't know the language \(targetName).")
        }
        let target = Locale.Language(identifier: code)
        guard let detected = NLLanguageRecognizer.dominantLanguage(for: text) else {
            throw ProviderError.unavailable("Couldn't detect the language of the text.")
        }
        let source = Locale.Language(identifier: detected.rawValue)
        if source.languageCode == target.languageCode { return text }

        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            break
        case .supported:
            throw ProviderError.unavailable(
                "Download \(detected.rawValue) → \(code) in System Settings → General → Language & Region → Translation Languages."
            )
        case .unsupported:
            throw ProviderError.unavailable("Apple Translation can't translate \(detected.rawValue) into \(code).")
        @unknown default:
            throw ProviderError.unavailable("Apple Translation is unavailable for this language pair.")
        }
        let session = TranslationSession(installedSource: source, target: target)
        return try await session.translate(text).targetText
    }
}
