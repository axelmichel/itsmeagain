import AppleIntelligence
import CompanionCore
import Foundation
import Observation
import Persistence
import Providers
import Routing
import SwiftData

/// App-wide state: configured providers, task → model mapping, routing, and the chat engine.
@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let providers = "providers"
        static let taskProfiles = "taskProfiles"
        static let lastTask = "lastTask"
        static let lastAuto = "lastAuto"
        static let defaultTargetLanguage = "defaultTargetLanguage"
        static let routerProvider = "routerProvider"
        static let routerModel = "routerModel"
        static let preferAppleRouter = "preferAppleRouter"
        static let legacyOllamaHost = "ollamaHost"
    }

    private let defaults: UserDefaults

    var providers: [ProviderConfig] {
        didSet { defaults.set(try? JSONEncoder().encode(providers), forKey: Keys.providers) }
    }

    var taskProfiles: TaskProfiles {
        didSet { defaults.set(try? JSONEncoder().encode(taskProfiles), forKey: Keys.taskProfiles) }
    }

    /// New conversations start in whatever mode the user picked last.
    var lastTask: TaskKind {
        didSet { defaults.set(lastTask.rawValue, forKey: Keys.lastTask) }
    }

    var lastAuto: Bool {
        didSet { defaults.set(lastAuto, forKey: Keys.lastAuto) }
    }

    var defaultTargetLanguage: String {
        didSet { defaults.set(defaultTargetLanguage, forKey: Keys.defaultTargetLanguage) }
    }

    /// Classifier for Auto mode when Apple Intelligence isn't used.
    var routerModel: ModelRef {
        didSet {
            defaults.set(routerModel.provider.rawValue, forKey: Keys.routerProvider)
            defaults.set(routerModel.model, forKey: Keys.routerModel)
        }
    }

    var preferAppleRouter: Bool {
        didSet { defaults.set(preferAppleRouter, forKey: Keys.preferAppleRouter) }
    }

    private(set) var models: [ProviderID: [ModelInfo]] = [:]
    private(set) var modelErrors: [ProviderID: String] = [:]
    private(set) var isLoadingModels = false

    let chat = ChatController()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var providers = defaults.data(forKey: Keys.providers)
            .flatMap { try? JSONDecoder().decode([ProviderConfig].self, from: $0) } ?? []
        for builtIn in ProviderConfig.builtIns where !providers.contains(where: { $0.id == builtIn.id }) {
            providers.insert(builtIn, at: min(providers.count, ProviderConfig.builtIns.firstIndex(of: builtIn)!))
        }
        if let host = defaults.string(forKey: Keys.legacyOllamaHost), let index = providers.firstIndex(where: { $0.id == .ollama }) {
            providers[index].baseURL = host
            defaults.removeObject(forKey: Keys.legacyOllamaHost)
        }
        self.providers = providers

        taskProfiles = defaults.data(forKey: Keys.taskProfiles)
            .flatMap { try? JSONDecoder().decode(TaskProfiles.self, from: $0) } ?? .defaults
        lastTask = defaults.string(forKey: Keys.lastTask).flatMap(TaskKind.init(rawValue:)) ?? .chat
        lastAuto = defaults.object(forKey: Keys.lastAuto) as? Bool ?? false
        defaultTargetLanguage = defaults.string(forKey: Keys.defaultTargetLanguage) ?? "English"
        routerModel = ModelRef(
            provider: ProviderID(defaults.string(forKey: Keys.routerProvider) ?? ProviderID.ollama.rawValue),
            model: defaults.string(forKey: Keys.routerModel) ?? "qwen3:8b"
        )
        preferAppleRouter = defaults.object(forKey: Keys.preferAppleRouter) as? Bool ?? true
    }

    // MARK: Providers

    var enabledProviders: [ProviderConfig] { providers.filter(\.enabled) }

    func config(for id: ProviderID) -> ProviderConfig? {
        providers.first { $0.id == id }
    }

    func provider(for id: ProviderID) -> (any LLMProvider)? {
        guard let config = config(for: id), config.enabled else { return nil }
        return config.makeProvider()
    }

    func displayName(for id: ProviderID) -> String {
        config(for: id)?.name ?? id.rawValue
    }

    func isAvailable(_ ref: ModelRef) -> Bool {
        models[ref.provider]?.contains { $0.id == ref.model } ?? false
    }

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        let enabled = enabledProviders.map { ($0.id, $0.makeProvider()) }
        let results = await withTaskGroup(of: (ProviderID, Result<[ModelInfo], Error>).self) { group in
            for (id, provider) in enabled {
                group.addTask {
                    do { return (id, .success(try await provider.listModels())) } catch { return (id, .failure(error)) }
                }
            }
            var results: [(ProviderID, Result<[ModelInfo], Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
        models = [:]
        modelErrors = [:]
        for (id, result) in results {
            switch result {
            case .success(let list): models[id] = list
            case .failure(let error): modelErrors[id] = error.localizedDescription
            }
        }
    }

    @discardableResult
    func addProvider(_ preset: ProviderConfig.Preset) -> ProviderConfig {
        let base = preset.kind == .anthropic ? "anthropic" : preset.name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? "provider"
        var id = ProviderID(base)
        var suffix = 2
        while config(for: id) != nil {
            id = ProviderID("\(base)-\(suffix)")
            suffix += 1
        }
        let name = preset.name.replacingOccurrences(of: #" \(.*\)"#, with: "", options: .regularExpression)
        let config = ProviderConfig(id: id, kind: preset.kind, name: name, baseURL: preset.baseURL)
        providers.append(config)
        return config
    }

    func removeProvider(_ id: ProviderID) {
        guard let config = config(for: id), !config.isBuiltIn else { return }
        providers.removeAll { $0.id == id }
        KeychainStore.setKey("", for: id.rawValue)
        models[id] = nil
        modelErrors[id] = nil
    }

    // MARK: Routing

    var appleRouterAvailable: Bool { AppleTaskClassifier.isAvailable }

    var router: TaskRouter {
        if preferAppleRouter && appleRouterAvailable {
            return TaskRouter(classifier: AppleTaskClassifier())
        }
        if let provider = provider(for: routerModel.provider) {
            return TaskRouter(classifier: LLMTaskClassifier(provider: provider, model: routerModel.model))
        }
        return TaskRouter(classifier: nil)
    }

    // MARK: Conversations

    /// What the next turn of `conversation` will use (for Auto: the last routed task's mapping).
    func effectiveModel(for conversation: Conversation) -> ModelRef {
        if let model = conversation.modelOverride {
            return ModelRef(provider: ProviderID(conversation.providerOverride ?? ProviderID.ollama.rawValue), model: model)
        }
        let profile = taskProfiles[conversation.task]
        return ModelRef(provider: profile.providerID, model: profile.modelID)
    }

    func targetLanguage(for conversation: Conversation) -> String {
        conversation.targetLanguage ?? defaultTargetLanguage
    }

    /// Switches to a fixed task; a per-conversation model override belongs to the old task, so it is dropped.
    func select(_ task: TaskKind, for conversation: Conversation) {
        guard conversation.task != task || conversation.autoRoute else { return }
        conversation.task = task
        conversation.autoRoute = false
        conversation.providerOverride = nil
        conversation.modelOverride = nil
        lastTask = task
        lastAuto = false
    }

    func selectAuto(for conversation: Conversation) {
        guard !conversation.autoRoute else { return }
        conversation.autoRoute = true
        conversation.providerOverride = nil
        conversation.modelOverride = nil
        lastAuto = true
    }

    func send(_ text: String, in conversation: Conversation, context: ModelContext) {
        chat.send(text, in: conversation, context: context) { [self] in
            var targetLanguage = targetLanguage(for: conversation)
            if conversation.autoRoute {
                let decision = await router.route(text)
                conversation.task = decision.task
                if let language = decision.targetLanguage { targetLanguage = language }
            }
            let ref = effectiveModel(for: conversation)
            guard let provider = provider(for: ref.provider) else {
                throw ProviderError.unavailable("\(displayName(for: ref.provider)) is disabled or not configured (Settings → Providers).")
            }
            return TurnPlan(
                provider: provider,
                profile: taskProfiles[conversation.task],
                model: ref.model,
                targetLanguage: targetLanguage
            )
        }
    }
}
