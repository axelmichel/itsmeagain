import CompanionCore
import Foundation
import Observation
import Persistence
import Providers
import Routing
import SwiftData

/// App-wide state: provider configuration, task → model mapping, available models, and the chat engine.
@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let ollamaHost = "ollamaHost"
        static let taskProfiles = "taskProfiles"
        static let lastTask = "lastTask"
        static let defaultTargetLanguage = "defaultTargetLanguage"
    }

    private let defaults: UserDefaults

    var ollamaHost: String {
        didSet { defaults.set(ollamaHost, forKey: Keys.ollamaHost) }
    }

    var taskProfiles: TaskProfiles {
        didSet { defaults.set(try? JSONEncoder().encode(taskProfiles), forKey: Keys.taskProfiles) }
    }

    /// Task used for new conversations: whatever the user picked last.
    var lastTask: TaskKind {
        didSet { defaults.set(lastTask.rawValue, forKey: Keys.lastTask) }
    }

    var defaultTargetLanguage: String {
        didSet { defaults.set(defaultTargetLanguage, forKey: Keys.defaultTargetLanguage) }
    }

    private(set) var models: [ModelInfo] = []
    private(set) var modelsError: String?
    private(set) var isLoadingModels = false

    let chat = ChatController()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ollamaHost = defaults.string(forKey: Keys.ollamaHost) ?? OllamaProvider.defaultBaseURL.absoluteString
        taskProfiles = defaults.data(forKey: Keys.taskProfiles)
            .flatMap { try? JSONDecoder().decode(TaskProfiles.self, from: $0) } ?? .defaults
        lastTask = defaults.string(forKey: Keys.lastTask).flatMap(TaskKind.init(rawValue:)) ?? .chat
        defaultTargetLanguage = defaults.string(forKey: Keys.defaultTargetLanguage) ?? "English"
    }

    var ollama: OllamaProvider {
        OllamaProvider(baseURL: URL(string: ollamaHost) ?? OllamaProvider.defaultBaseURL)
    }

    /// Only Ollama exists so far; cloud and Apple providers plug in here.
    func provider(for id: ProviderID) -> any LLMProvider {
        ollama
    }

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await ollama.listModels()
            modelsError = nil
        } catch {
            models = []
            modelsError = error.localizedDescription
        }
    }

    // MARK: Conversations

    /// The model the next turn of `conversation` will use.
    func effectiveModel(for conversation: Conversation) -> String {
        conversation.modelOverride ?? taskProfiles[conversation.task].modelID
    }

    func targetLanguage(for conversation: Conversation) -> String {
        conversation.targetLanguage ?? defaultTargetLanguage
    }

    /// Switches task; a per-conversation model override belongs to the old task, so it is dropped.
    func select(_ task: TaskKind, for conversation: Conversation) {
        guard conversation.task != task else { return }
        conversation.task = task
        conversation.providerOverride = nil
        conversation.modelOverride = nil
        lastTask = task
    }

    func send(_ text: String, in conversation: Conversation, context: ModelContext) {
        let profile = taskProfiles[conversation.task]
        let providerID = conversation.providerOverride.map { ProviderID($0) } ?? profile.providerID
        chat.send(
            text,
            in: conversation,
            using: provider(for: providerID),
            profile: profile,
            model: effectiveModel(for: conversation),
            targetLanguage: targetLanguage(for: conversation),
            context: context
        )
    }
}
