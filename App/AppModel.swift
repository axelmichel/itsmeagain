import AppleIntelligence
import CompanionCore
import Foundation
import Knowledge
import Observation
import Persistence
import Providers
import Routing
import SwiftData
import SwiftUI
import Tools

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
        static let searchBackend = "searchBackend"
        static let searxngURL = "searxngURL"
        static let legacyOllamaHost = "ollamaHost"
        static let quickPanelShortcut = "quickPanelShortcut"
        static let showMenuBarIcon = "showMenuBarIcon"
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

    var searchBackend: SearchBackendKind {
        didSet { defaults.set(searchBackend.rawValue, forKey: Keys.searchBackend) }
    }

    var searxngURL: String {
        didSet { defaults.set(searxngURL, forKey: Keys.searxngURL) }
    }

    private(set) var models: [ProviderID: [ModelInfo]] = [:]
    private(set) var modelErrors: [ProviderID: String] = [:]
    private(set) var isLoadingModels = false

    let chat = ChatController()
    let knowledge: KnowledgeModel

    // MARK: Quick panel & windows

    var quickPanelShortcut: HotKeyShortcut? {
        didSet {
            defaults.set(try? JSONEncoder().encode(quickPanelShortcut), forKey: Keys.quickPanelShortcut)
            registerHotKey()
        }
    }

    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Keys.showMenuBarIcon) }
    }

    /// False when the system refused the shortcut (usually another app owns it).
    private(set) var hotKeyRegistered = true
    /// The main window selects this conversation when set (e.g. "Open in ItsMeAgain" from the quick panel).
    var requestedConversation: PersistentIdentifier?
    @ObservationIgnored private(set) var quickPanel: QuickPanelController?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    /// SwiftUI's openWindow, captured from a view that lives as long as the app (the menu bar label).
    @ObservationIgnored var openWindowAction: OpenWindowAction?

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
        searchBackend = defaults.string(forKey: Keys.searchBackend).flatMap(SearchBackendKind.init(rawValue:)) ?? .wikipedia
        searxngURL = defaults.string(forKey: Keys.searxngURL) ?? "http://localhost:8888"
        quickPanelShortcut = defaults.data(forKey: Keys.quickPanelShortcut)
            .flatMap { try? JSONDecoder().decode(HotKeyShortcut?.self, from: $0) } ?? .optionSpace
        showMenuBarIcon = defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true
        knowledge = KnowledgeModel(defaults: defaults)
        knowledge.ollama = { [weak self] in self?.ollamaProvider ?? OllamaProvider() }
    }

    func installQuickPanel(container: ModelContainer) {
        quickPanel = QuickPanelController(app: self, container: container)
        hotKey = GlobalHotKey { [weak self] in self?.quickPanel?.toggle() }
        registerHotKey()
    }

    /// Temporarily off while the user records a new shortcut.
    func suspendHotKey(_ suspended: Bool) {
        suspended ? hotKey?.unregister() : registerHotKey()
    }

    private func registerHotKey() {
        guard let hotKey else { return }
        if let quickPanelShortcut {
            hotKeyRegistered = hotKey.register(quickPanelShortcut)
        } else {
            hotKey.unregister()
            hotKeyRegistered = true
        }
    }

    func openMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
    }

    /// The configured Ollama server, also used for embeddings and model downloads.
    var ollamaProvider: OllamaProvider {
        (config(for: .ollama)?.makeProvider() as? OllamaProvider) ?? OllamaProvider()
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
        let base = preset.kind == .anthropic ? "anthropic" : preset.kind == .claudeCode ? "claude-code" : preset.name.lowercased()
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

    // MARK: Tools

    func makeSearchBackend() -> any SearchBackend {
        switch searchBackend {
        case .wikipedia:
            return WikipediaSearchBackend()
        case .searxng:
            return SearXNGBackend(baseURL: URL(string: searxngURL) ?? URL(string: "http://localhost:8888")!)
        case .brave:
            return BraveSearchBackend(apiKey: KeychainStore.key(for: SearchBackendKind.brave.keychainAccount) ?? "")
        case .ollama:
            return OllamaWebSearchBackend(apiKey: KeychainStore.key(for: SearchBackendKind.ollama.keychainAccount) ?? "")
        }
    }

    func makeTools(for profile: TaskProfile) -> [any Tool] {
        profile.tools.compactMap { name -> (any Tool)? in
            switch name {
            case TaskProfile.ToolName.webSearch:
                // Self-hosted or keyed backends can be offline; Wikipedia always answers.
                WebSearchTool(backend: makeSearchBackend(), fallback: searchBackend == .wikipedia ? nil : WikipediaSearchBackend())
            case TaskProfile.ToolName.fetchPage: FetchPageTool()
            case TaskProfile.ToolName.searchDocuments: knowledge.makeTool()
            default: nil
            }
        }
    }

    // MARK: Conversations

    /// What the next turn of `conversation` will use (for Auto: the last routed task's mapping).
    func effectiveModel(for conversation: Conversation) -> ModelRef {
        let profile = taskProfiles[conversation.task]
        return ModelRef(provider: profile.providerID, model: profile.modelID)
    }

    func targetLanguage(for conversation: Conversation) -> String {
        conversation.targetLanguage ?? defaultTargetLanguage
    }

    /// Switches the conversation to a fixed task (its model comes from the task mapping).
    func select(_ task: TaskKind, for conversation: Conversation) {
        guard conversation.task != task || conversation.autoRoute else { return }
        conversation.task = task
        conversation.autoRoute = false
        lastTask = task
        lastAuto = false
    }

    func selectAuto(for conversation: Conversation) {
        guard !conversation.autoRoute else { return }
        conversation.autoRoute = true
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
            let profile = taskProfiles[conversation.task]
            return TurnPlan(
                provider: provider,
                profile: profile,
                model: ref.model,
                targetLanguage: targetLanguage,
                tools: makeTools(for: profile)
            )
        }
    }
}

enum SearchBackendKind: String, CaseIterable, Identifiable {
    case wikipedia, searxng, brave, ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wikipedia: "Wikipedia (no setup)"
        case .searxng: "SearXNG (self-hosted)"
        case .brave: "Brave Search API"
        case .ollama: "Ollama Web Search"
        }
    }

    var keychainAccount: String { "search.\(rawValue)" }
    var needsAPIKey: Bool { self == .brave || self == .ollama }
}
