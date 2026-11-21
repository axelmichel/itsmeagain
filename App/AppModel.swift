import AppleIntelligence
import CompanionCore
import Foundation
import Knowledge
import Mail
import Memory
import Obsidian
import PersonalData
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
    let approvals = ApprovalCenter()
    let commands = CommandCenter()
    @ObservationIgnored let notifier = Notifier()
    let memory = MemoryModel()
    @ObservationIgnored private(set) var scheduler: AutomationScheduler?

    enum SidebarMode: String { case chats, automations, memory }

    // MARK: Assistant settings

    /// Calendars and reminder lists the assistant must not see (identifiers).
    var hiddenCalendars: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendars") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(hiddenCalendars), forKey: "hiddenCalendars")
            let hidden = hiddenCalendars
            Task { await EventKitStore.shared.setHiddenCalendars(hidden) }
        }
    }

    /// Lets create_reminder run without an approval card.
    var remindersWithoutAsking: Bool = UserDefaults.standard.bool(forKey: "remindersWithoutAsking") {
        didSet { UserDefaults.standard.set(remindersWithoutAsking, forKey: "remindersWithoutAsking") }
    }

    /// Apple Mail for the assistant (asks macOS for permission on first use).
    var mailEnabled: Bool = UserDefaults.standard.object(forKey: "mailEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mailEnabled, forKey: "mailEnabled") }
    }

    var excludedMailAccounts: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "excludedMailAccounts") ?? []) {
        didSet { UserDefaults.standard.set(Array(excludedMailAccounts), forKey: "excludedMailAccounts") }
    }

    /// Comma- or line-separated addresses / names.
    var vipSenders: String = UserDefaults.standard.string(forKey: "vipSenders") ?? "" {
        didSet { UserDefaults.standard.set(vipSenders, forKey: "vipSenders") }
    }

    var newsletterSenders: String = UserDefaults.standard.string(forKey: "newsletterSenders") ?? "" {
        didSet { UserDefaults.standard.set(newsletterSenders, forKey: "newsletterSenders") }
    }

    var mailPreferences: MailPreferences {
        // Senders the user sorted into Digest or Junk count as automated mail too.
        let ruled = senderRules.rules.filter { $0.action != .keep }.map(\.key)
        return MailPreferences(
            excludedAccounts: excludedMailAccounts, vipSenders: Self.split(vipSenders), newsletterSenders: Self.split(newsletterSenders) + ruled
        )
    }

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What the user decided per mailing-list sender (Junk / Digest / Keep); junk rules run automatically.
    var senderRules: SenderRuleBook = UserDefaults.standard.data(forKey: "senderRules")
        .flatMap { try? JSONDecoder().decode(SenderRuleBook.self, from: $0) } ?? SenderRuleBook() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(senderRules), forKey: "senderRules") }
    }

    /// Topics the newsletter digest keeps, comma-separated.
    var newsletterTopics: String = UserDefaults.standard.string(forKey: "newsletterTopics")
        ?? NewsletterDigest.defaultTopics.joined(separator: ", ") {
        didSet { UserDefaults.standard.set(newsletterTopics, forKey: "newsletterTopics") }
    }

    var newsletterTopicList: [String] {
        let topics = Self.split(newsletterTopics)
        return topics.isEmpty ? NewsletterDigest.defaultTopics : topics
    }

    /// The Chat task's model, for mail decisions and digests — only if it runs locally.
    func localMailModel() throws -> MailModel {
        let profile = taskProfiles[.chat]
        guard let config = config(for: profile.providerID), config.isLocal, let provider = provider(for: profile.providerID) else {
            throw ProviderError.unavailable("Mail cleanup needs a local Chat model. Choose one in Settings → Tasks → Chat.")
        }
        return MailModel(provider: provider, model: profile.modelID)
    }

    let mailSource: any MailSource = AppleMailSource()
    @ObservationIgnored private(set) var mailWatcher: MailWatcher?

    /// Check new mail every five minutes in the background.
    var mailWatchEnabled: Bool = UserDefaults.standard.object(forKey: "mailWatchEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(mailWatchEnabled, forKey: "mailWatchEnabled")
            if mailWatchEnabled { mailWatcher?.checkSoon() }
        }
    }

    /// A notification per important sender with new mail (Settings → Important senders).
    var notifyImportantMail: Bool = UserDefaults.standard.object(forKey: "notifyImportantMail") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyImportantMail, forKey: "notifyImportantMail") }
    }

    /// Read new mail for appointments (invitations exactly, other mail with the local model).
    var findAppointmentsInMail: Bool = UserDefaults.standard.object(forKey: "findAppointmentsInMail") as? Bool ?? true {
        didSet { UserDefaults.standard.set(findAppointmentsInMail, forKey: "findAppointmentsInMail") }
    }

    // MARK: Obsidian

    /// Vaults Obsidian knows about (refreshed when Settings opens).
    var detectedVaults: [Vault] = Vault.detect()

    /// Vaults the assistant may use; nil until chosen = the vaults open in Obsidian.
    var enabledVaultPaths: [String]? = UserDefaults.standard.stringArray(forKey: "enabledVaults") {
        didSet { UserDefaults.standard.set(enabledVaultPaths, forKey: "enabledVaults") }
    }

    /// Where the daily note and captures go.
    var mainVaultPath: String? = UserDefaults.standard.string(forKey: "mainVault") {
        didSet { UserDefaults.standard.set(mainVaultPath, forKey: "mainVault") }
    }

    var dailyNoteWithoutAsking: Bool = UserDefaults.standard.bool(forKey: "dailyNoteWithoutAsking") {
        didSet { UserDefaults.standard.set(dailyNoteWithoutAsking, forKey: "dailyNoteWithoutAsking") }
    }

    func isVaultEnabled(_ vault: Vault) -> Bool {
        enabledVaultPaths.map { $0.contains(vault.path) } ?? vault.isOpen
    }

    func setVault(_ vault: Vault, enabled: Bool) {
        var paths = Set(enabledVaultPaths ?? detectedVaults.filter(\.isOpen).map(\.path))
        if enabled { paths.insert(vault.path) } else { paths.remove(vault.path) }
        enabledVaultPaths = paths.sorted()
    }

    /// Enabled vaults, the main one first.
    var vaults: VaultSet {
        let enabled = detectedVaults.filter(isVaultEnabled)
        let main = enabled.first { $0.path == mainVaultPath } ?? enabled.first
        let ordered = (main.map { [$0] } ?? []) + enabled.filter { $0.path != main?.path }
        return VaultSet(stores: ordered.map { NoteStore(vault: $0) })
    }

    /// Calendar, reminder and mail tools — only ever added to local-only tasks.
    var personalTools: [any Tool] {
        var tools = CalendarToolbox.tools(
            store: EventKitStore.shared, events: EventKitStore.eventsAuthorized, reminders: EventKitStore.remindersAuthorized
        )
        if mailEnabled { tools += MailToolbox.tools(source: mailSource, preferences: mailPreferences) }
        tools += [RecallTool(memory: memory), RememberTool(memory: memory)]
        tools += ObsidianToolbox.tools(vaults)
        return tools
    }

    // MARK: Task notifications

    /// A macOS notification when a long reply or command finishes while you're elsewhere.
    var notifyWhenDone: Bool = UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyWhenDone, forKey: "notifyWhenDone")
            if notifyWhenDone { Task { await notifier.requestPermission() } }
        }
    }

    /// Only tasks that ran at least this long (seconds).
    var notifyAfterSeconds: Int = UserDefaults.standard.object(forKey: "notifyAfterSeconds") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(notifyAfterSeconds, forKey: "notifyAfterSeconds") }
    }

    /// Show the start of the answer in the notification (off keeps mail and calendar details off the screen).
    var notifyWithPreview: Bool = UserDefaults.standard.object(forKey: "notifyWithPreview") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notifyWithPreview, forKey: "notifyWithPreview") }
    }

    /// The conversation shown in the main window, so finishing it while you watch doesn't notify.
    var visibleConversation: PersistentIdentifier?

    private func taskFinished(_ conversation: Conversation, reply: StoredMessage?, duration: Duration) {
        let key = conversation.persistentModelID
        guard notifyWhenDone, duration >= .seconds(notifyAfterSeconds), !chat.quiet.contains(key) else { return }
        if NSApp.isActive, visibleConversation == key { return }
        let failed = reply?.errorText != nil
        let title = (failed ? "Failed: " : "Done: ") + conversation.title
        var body = failed ? reply?.errorText ?? "" : "Finished after \(Self.durationText(duration))."
        if notifyWithPreview, !failed, let content = reply?.content, !content.isEmpty {
            body = AutomationScheduler.summary(of: content)
        }
        notifier.post(title: title, body: body, conversationID: conversation.id)
    }

    private static func durationText(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds < 90 ? "\(seconds) s" : "\(seconds / 60) min"
    }

    /// Write tools the user allowed globally.
    var standingApprovals: Set<String> {
        var allowed: Set<String> = []
        if remindersWithoutAsking { allowed.insert(PersonalToolName.createReminder) }
        if dailyNoteWithoutAsking { allowed.insert(ObsidianToolName.appendDailyNote) }
        return allowed
    }

    /// What the sidebar lists (persisted).
    var sidebarMode: SidebarMode = SidebarMode(rawValue: UserDefaults.standard.string(forKey: "sidebarMode") ?? "") ?? .chats {
        didSet { UserDefaults.standard.set(sidebarMode.rawValue, forKey: "sidebarMode") }
    }
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
    /// Sidebar "Rename…": the header starts editing this conversation's title.
    var renameRequest: PersistentIdentifier?
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
        let hidden = Set(defaults.stringArray(forKey: "hiddenCalendars") ?? [])
        Task { await EventKitStore.shared.setHiddenCalendars(hidden) }
        knowledge.ollama = { [weak self] in self?.ollamaProvider ?? OllamaProvider() }
    }

    func installQuickPanel(container: ModelContainer) {
        quickPanel = QuickPanelController(app: self, container: container)
        hotKey = GlobalHotKey { [weak self] in self?.quickPanel?.toggle() }
        registerHotKey()
    }

    /// Automations and notifications (clicking a notification opens its conversation).
    func installAssistant(container: ModelContainer) {
        ChatController.markInterruptedReplies(in: container.mainContext)
        chat.onFinished = { [unowned self] conversation, reply, duration in
            taskFinished(conversation, reply: reply, duration: duration)
        }
        if notifyWhenDone { Task { await notifier.requestPermission() } }
        notifier.onOpenConversation = { [weak self] id in
            guard let self,
                let conversation = try? container.mainContext.fetch(
                    FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
                ).first
            else { return }
            sidebarMode = .chats
            requestedConversation = conversation.persistentModelID
            openMainWindow()
        }
        notifier.onOpenMemory = { [weak self] in
            self?.sidebarMode = .memory
            self?.openMainWindow()
        }
        let scheduler = AutomationScheduler(app: self, container: container, notifier: notifier)
        self.scheduler = scheduler
        scheduler.start()

        memory.chatModel = { [unowned self] in
            let model = try localMailModel()
            return (model.provider, model.model)
        }
        memory.embedder = { [unowned self] in (knowledge.embedder, knowledge.embeddingModel) }
        memory.onLearned = { [unowned self] pending in
            notifier.post(
                title: "ItsMeAgain noticed something",
                body: pending == 1 ? "1 new thing about you to review" : "\(pending) new things about you to review",
                conversationID: nil,
                opensMemory: true
            )
        }
        Task { await memory.load() }
        let mailWatcher = MailWatcher(app: self, container: container)
        self.mailWatcher = mailWatcher
        mailWatcher.start()
        memory.startLearning(container: container) { [unowned self] in chat.isBusy }
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

    /// Brings the main window forward, recreating it if the user closed it.
    func openMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
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

    /// The task's tools; local-only tasks (Chat) also get the personal tools the user granted access to.
    func makeTools(for profile: TaskProfile) -> [any Tool] {
        var tools = makeTools(named: profile.tools)
        if profile.localOnly { tools += personalTools }
        return tools
    }

    func makeTools(named names: [String]) -> [any Tool] {
        let personal = personalTools
        return names.compactMap { name -> (any Tool)? in
            if let tool = personal.first(where: { $0.spec.name == name }) { return tool }
            switch name {
            case TaskProfile.ToolName.webSearch:
                // Self-hosted or keyed backends can be offline; Wikipedia always answers.
                return WebSearchTool(backend: makeSearchBackend(), fallback: searchBackend == .wikipedia ? nil : WikipediaSearchBackend())
            case TaskProfile.ToolName.fetchPage: return FetchPageTool()
            case TaskProfile.ToolName.searchDocuments: return knowledge.makeTool()
            default: return nil
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

    /// Sends a message (or, with `command`, a command's expanded prompt) through the normal turn pipeline.
    func send(_ text: String, in conversation: Conversation, context: ModelContext, command: CommandInvocation? = nil) {
        chat.send(text, modelText: command?.modelText, in: conversation, context: context) { [self] in
            var targetLanguage = targetLanguage(for: conversation)
            if let command {
                // Commands name their task; no routing.
                conversation.task = command.task
            } else if conversation.autoRoute {
                let decision = await router.route(text)
                conversation.task = decision.task
                if let language = decision.targetLanguage { targetLanguage = language }
            }
            let ref = effectiveModel(for: conversation)
            guard let config = config(for: ref.provider), let provider = provider(for: ref.provider) else {
                throw ProviderError.unavailable("\(displayName(for: ref.provider)) is disabled or not configured (Settings → Providers).")
            }
            let profile = taskProfiles[conversation.task]
            // Chat is the personal assistant: it sees private data, so it never runs on a cloud model.
            if profile.localOnly && !config.isLocal {
                throw ProviderError.unavailable(
                    "\(conversation.task.title) runs on local models only. Choose a local model in Settings → Tasks → \(conversation.task.title)."
                )
            }
            let approvals = approvals
            // Memory only for local-only tasks (Chat) on a local provider — never for cloud models.
            let memoryContext = profile.localOnly ? await memory.context(for: text, providerIsLocal: config.isLocal) : nil
            return TurnPlan(
                provider: provider,
                profile: profile,
                model: ref.model,
                targetLanguage: targetLanguage,
                tools: command?.tools.map { makeTools(named: $0) } ?? makeTools(for: profile),
                policy: ToolPolicy(
                    providerIsLocal: config.isLocal,
                    autoApproved: (command?.autoApproved ?? []).union(profile.localOnly ? standingApprovals : [])
                ) { request in
                    await approvals.request(request)
                },
                finalize: command?.finalize,
                systemSuffix: memoryContext
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
