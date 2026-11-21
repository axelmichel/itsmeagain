import AppKit
import UniformTypeIdentifiers
import Mail
import Jira
import Weather
import Memory
import News
import Obsidian
import PersonalData
import SwiftUI

/// What Chat (the personal assistant) may see and do.
struct AssistantSettings: View {
    @Environment(AppModel.self) private var app
    @State private var calendars: [CalendarInfo] = []
    @State private var lists: [CalendarInfo] = []
    @State private var eventsAuthorized = EventKitStore.eventsAuthorized
    @State private var remindersAuthorized = EventKitStore.remindersAuthorized

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                LabeledContent("Calendars") { status(eventsAuthorized, denied: EventKitStore.eventsDenied) }
                LabeledContent("Reminders") { status(remindersAuthorized, denied: EventKitStore.remindersDenied) }
                if !eventsAuthorized || !remindersAuthorized {
                    HStack {
                        Button("Allow Access…") {
                            Task {
                                _ = await EventKitStore.shared.requestAccess()
                                await reload()
                            }
                        }
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                }
            } header: {
                Text("Access")
            } footer: {
                Text("Used only by Chat, which always runs on a local model. Events and reminders never leave this Mac.")
                    .foregroundStyle(.secondary)
            }

            if eventsAuthorized && !calendars.isEmpty {
                Section("Visible Calendars") {
                    ForEach(calendars) { visibilityToggle($0) }
                }
            }
            if remindersAuthorized && !lists.isEmpty {
                Section("Visible Reminder Lists") {
                    ForEach(lists) { visibilityToggle($0) }
                }
            }

            MailSettingsSection()
                if app.mailEnabled { MailRulesSection() }
                ObsidianSettingsSection()
                NewsSettingsSection()
                JiraSettingsSection()
                WeatherSettingsSection()
                LearningSettingsSection()
                MemorySettingsSection()

            Section {
                Toggle("Create reminders without asking", isOn: $app.remindersWithoutAsking)
                Picker("/planday puts tasks into", selection: $app.planDayList) {
                    Text("Default list").tag("")
                    ForEach(lists) { Text($0.title).tag($0.title) }
                }
            } header: {
                Text("Approvals")
            } footer: {
                Text("Creating or moving events, completing reminders and opening mail drafts always ask first. Mail is never sent by the assistant.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 700)
        .task { await reload() }
    }

    private func status(_ authorized: Bool, denied: Bool) -> some View {
        Group {
            if authorized {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if denied {
                Text("Denied — allow in System Settings → Privacy & Security").foregroundStyle(.orange)
            } else {
                Text("Not yet allowed").foregroundStyle(.secondary)
            }
        }
    }

    private func visibilityToggle(_ calendar: CalendarInfo) -> some View {
        Toggle(isOn: Binding(
            get: { !app.hiddenCalendars.contains(calendar.id) },
            set: { visible in
                if visible { app.hiddenCalendars.remove(calendar.id) } else { app.hiddenCalendars.insert(calendar.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(calendar.title)
                Text(calendar.source + (calendar.allowsWrites ? "" : " · read-only"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        eventsAuthorized = EventKitStore.eventsAuthorized
        remindersAuthorized = EventKitStore.remindersAuthorized
        calendars = await EventKitStore.shared.calendars()
        lists = await EventKitStore.shared.reminderLists()
    }
}

private struct MailSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var accounts: [String] = []
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        @Bindable var app = app
        Section {
            Toggle("Use Apple Mail", isOn: $app.mailEnabled)
            if app.mailEnabled {
                HStack {
                    Button("Check Mail Access") { Task { await check() } }
                        .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                }
                ForEach(accounts, id: \.self) { account in
                    Toggle(account, isOn: Binding(
                        get: { !app.excludedMailAccounts.contains(account) },
                        set: { included in
                            if included { app.excludedMailAccounts.remove(account) } else { app.excludedMailAccounts.insert(account) }
                        }
                    ))
                }
                ImportantSendersEditor()
                Toggle("Check new mail in the background", isOn: $app.mailWatchEnabled)
                if app.mailWatchEnabled {
                    Toggle("Notify me about mail from important senders", isOn: $app.notifyImportantMail)
                        .padding(.leading, 16)
                    Toggle("Find appointments in new mail and ask me", isOn: $app.findAppointmentsInMail)
                        .padding(.leading, 16)
                }
                LabeledContent("Newsletter senders") {
                    TextField("digest@, news.example.com", text: $app.newsletterSenders, axis: .vertical)
                        .lineLimit(1...3)
                }
            }
        } header: {
            Text("Mail")
        } footer: {
            Text("""
                Reads recent mail from Apple Mail (all accounts configured there) on this Mac only. macOS asks once to \
                let ItsMeAgain control Mail. Important senders come first in /inbox, /triage and the brief; automated \
                senders (noreply, newsletters) are summarised in one line. The background check runs every five \
                minutes: new unread mail from important senders notifies you (one notification per sender), and \
                appointments found in the last week's mail, read or unread (invitations, or text read by your local \
                model), are checked against your calendar and offered once with Add / Ignore in the "Mail watch" \
                conversation. Nothing is added without your click.
                """)
            .foregroundStyle(.secondary)
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            accounts = try await app.mailSource.accounts()
            status = "Connected · \(accounts.count) accounts"
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Digest topics and the per-sender decisions from /cleanup.
private struct MailRulesSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Section {
            LabeledContent("Digest topics") {
                TextField(NewsletterDigest.defaultTopics.joined(separator: ", "), text: $app.newsletterTopics, axis: .vertical)
                    .lineLimit(1...3)
            }
            if app.senderRules.rules.isEmpty {
                Text("No rules yet. Run /cleanup and choose Junk, Digest or Keep per sender.")
                    .foregroundStyle(.secondary)
            }
            ForEach(SenderAction.allCases, id: \.self) { action in
                let rules = app.senderRules.rules.filter { $0.action == action }
                if !rules.isEmpty {
                    DisclosureGroup("\(action.title) (\(rules.count))") {
                        ForEach(rules) { rule in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rule.name ?? rule.key)
                                    if rule.name != nil {
                                        Text(rule.key).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Menu {
                                    ForEach(SenderAction.allCases.filter { $0 != action }, id: \.self) { other in
                                        Button("Change to \(other.title)") { app.senderRules.set(rule.key, other, name: rule.name) }
                                    }
                                    Divider()
                                    Button("Forget", role: .destructive) { app.senderRules.remove(rule.key) }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Spam & Newsletters")
        } footer: {
            Text("""
                Junk rules run on every /cleanup (and its automation) and move that mail to Junk. Digest senders are \
                summarised by /digest for your topics, then marked read and archived. Rules for a whole domain \
                (@brand.com) only cover mailing-list mail, and order, shipping, invoice and account mail is never \
                junked or archived by a rule. New mailing lists get a \
                suggestion from your local Chat model, based on the choices you made before; mail only moves on your \
                rules, never on a suggestion.
                """)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MemorySettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var memory = app.memory
        Section {
            Toggle("Learn from my Chat messages", isOn: $memory.learningEnabled)
            LabeledContent("Accept without asking") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(MemoryKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { memory.autoAccept.contains(kind) },
                            set: { on in if on { memory.autoAccept.insert(kind) } else { memory.autoAccept.remove(kind) } }
                        ))
                    }
                }
            }
            HStack {
                Text("\(memory.book.active.count) memories, \(memory.book.pending.count) to review")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppData.memory]) }
                Button("Open Memory") { app.sidebarMode = .memory; app.openMainWindow() }
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("""
                After a Chat conversation has been idle for ten minutes, your local Chat model reads your own messages \
                in it (never mail, web pages, tool results or its own replies) and proposes lasting facts. Kinds checked \
                above are kept right away; everything else, updates of known facts and anything sensitive waits for your \
                review in the Memory tab. Memory is only used in Chat mode and only with local models.
                """)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ObsidianSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Section {
            if app.detectedVaults.isEmpty {
                Text("No Obsidian vaults found. Open your vault in Obsidian once, then come back.")
                    .foregroundStyle(.secondary)
            }
            ForEach(app.detectedVaults) { vault in
                Toggle(isOn: Binding(get: { app.isVaultEnabled(vault) }, set: { app.setVault(vault, enabled: $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vault.name)
                        Text(vault.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            let enabled = app.detectedVaults.filter(app.isVaultEnabled)
            if enabled.count > 1 {
                Picker("Main vault", selection: Binding(
                    get: { app.vaults.main?.vault.path ?? "" },
                    set: { app.mainVaultPath = $0 }
                )) {
                    ForEach(enabled) { Text($0.name).tag($0.path) }
                }
            }
            Toggle("Add to the daily note without asking", isOn: $app.dailyNoteWithoutAsking)
            Toggle("Write the morning brief and today's events into the daily note", isOn: $app.briefToDailyNote)
            Toggle("/planday also writes the tasks into today's daily note", isOn: $app.planDayToDailyNote)
            ForEach(enabled) { vault in
                let status = app.vaultIndex.status[vault.path]
                LabeledContent("Search index · \(vault.name)") {
                    Text(status?.progress ?? status?.error.map { "Not ready: \($0)" }
                        ?? status?.lastIndexed.map { "\(status?.files ?? 0) notes · \($0.formatted(.relative(presentation: .named)))" }
                        ?? "Waiting…")
                        .foregroundStyle(status?.error == nil ? Color.secondary : Color.orange)
                }
            }
            HStack {
                Spacer()
                Button("Update Index Now") { Task { await app.vaultIndex.indexAll() } }
                    .disabled(app.vaultIndex.isIndexing)
                Button("Rebuild Index") { app.vaultIndex.rebuild() }
                    .disabled(app.vaultIndex.isIndexing)
            }
        } header: {
            Text("Obsidian")
        } footer: {
            Text("""
                Chat can search (by meaning, with your local embedding model, and by words) and read the enabled vaults \
                and list their tasks. It writes lines in today's daily note, new notes in Inbox/ and ticked tasks — \
                each after your approval, or because you typed /note, /capture, /dayplan or ticked it yourself. \
                Commands use the main vault unless you start with @vault, e.g. /capture @cooking Leek soup — …. Nothing is deleted, renamed or overwritten, and the \
                app never commits: changes appear as uncommitted changes in your vault's git.
                """)
            .foregroundStyle(.secondary)
        }
        .onAppear { app.detectedVaults = Vault.detect() }
    }
}

private struct NewsSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var newURL = ""
    @State private var adding = false
    @State private var message: String?

    var body: some View {
        @Bindable var app = app
        let news = app.news
        Section {
            LabeledContent("Interests") {
                TextField(NewsDigestDefaults.topics.joined(separator: ", "), text: $app.newsletterTopics, axis: .vertical)
                    .lineLimit(1...3)
            }
            DisclosureGroup("Feeds (\(news.library.feeds.filter(\.enabled).count) of \(news.library.feeds.count) on)") {
                ForEach(news.library.feeds) { feed in
                    HStack {
                        Toggle(isOn: Binding(get: { feed.enabled }, set: { news.setEnabled(feed.url, $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feed.title)
                                Text(feed.lastError.map { "Couldn't load: \($0)" } ?? feed.url)
                                    .font(.caption)
                                    .foregroundStyle(feed.lastError == nil ? Color.secondary : Color.orange)
                                    .lineLimit(1)
                            }
                        }
                        Button("Remove", systemImage: "minus.circle") { news.remove(feed.url) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("Add a feed: https://…/feed.xml", text: $newURL)
                    .onSubmit(add)
                if adding { ProgressView().controlSize(.small) }
                Button("Add", action: add).disabled(newURL.isEmpty || adding)
            }
            HStack {
                Button("Import OPML…", action: importOPML)
                Button("Restore Suggested Feeds") { news.restoreDefaults() }
                Spacer()
                if news.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh Now") { Task { await news.refresh() } }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(news.library.items.count) articles from the last 30 days" + (news.lastRefresh.map { " · updated \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("News")
        } footer: {
            Text("""
                Public RSS/Atom feeds — the suggested ones are sources daily.dev aggregates. Refreshed hourly; articles \
                are matched to your interests (and projects from your memory) on this Mac. /news lists today's best \
                matches, Chat can ask about them, and the morning brief ends with three headlines.
                """)
            .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let url = newURL
        adding = true
        Task {
            do {
                let feed = try await app.news.addFeed(url)
                message = "Added \(feed.title)."
                newURL = ""
            } catch {
                message = "Couldn't add it: \(error.localizedDescription)"
            }
            adding = false
        }
    }

    private func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let added = app.news.importOPML(data)
        message = added == 0 ? "No new feeds in that file." : "Imported \(added) feeds."
    }
}

private struct JiraSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var url = ""
    @State private var email = ""
    @State private var token = ""
    @State private var messages: [UUID: String] = [:]
    @State private var adding = false

    var body: some View {
        let jira = app.jira
        Section {
            ForEach(jira.connections) { connection in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle(isOn: Binding(
                            get: { connection.enabled },
                            set: { on in var updated = connection; updated.enabled = on; jira.update(updated, token: nil) }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(connection.name)
                                Text(connection.baseURL).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if jira.testing.contains(connection.id) { ProgressView().controlSize(.small) }
                        Button("Test") { Task { messages[connection.id] = await jira.test(connection.id) } }
                            .disabled(jira.testing.contains(connection.id))
                        Button("Remove", systemImage: "minus.circle") { jira.remove(connection.id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    if let message = messages[connection.id] ?? connection.lastError {
                        Text(message).font(.caption).foregroundStyle(connection.lastError == nil ? Color.secondary : Color.orange)
                    } else if !connection.projectKeys.isEmpty {
                        Text("\(connection.kind == .cloud ? "Cloud" : "Data Center") · \(connection.projectKeys.count) projects")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !jira.hasToken(connection) {
                        Text("No token saved.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            DisclosureGroup("Add a Jira site", isExpanded: $adding) {
                TextField("Name", text: $name, prompt: Text("e.g. Work"))
                TextField("Address", text: $url, prompt: Text("https://yourcompany.atlassian.net"))
                TextField("Email (Cloud)", text: $email, prompt: Text("Your Atlassian account email"))
                SecureField("API token", text: $token, prompt: Text("Cloud: API token · Data Center: personal access token"))
                HStack {
                    Spacer()
                    Button("Add and Test") {
                        let connection = jira.add(name: name, url: url, email: email, token: token)
                        name = ""; url = ""; email = ""; token = ""
                        adding = false
                        Task { messages[connection.id] = await jira.test(connection.id) }
                    }
                    .disabled(!url.lowercased().hasPrefix("https://") || token.isEmpty)
                }
            }
        } header: {
            Text("Jira")
        } footer: {
            Text("""
                Read-only: the app only ever reads tickets (it has no way to change one). Tokens are kept in the macOS \
                Keychain. On Jira Cloud, a scoped token with only read:jira-work and read:jira-user makes Jira itself \
                enforce read-only. Ticket text is used in Chat on your local model only. /jira KEY-1, /myjira.
                """)
            .foregroundStyle(.secondary)
        }
    }
}

/// Important senders: the ones typed here and the ones marked "Important" in /triage, in one list.
private struct ImportantSendersEditor: View {
    @Environment(AppModel.self) private var app
    @State private var newSender = ""

    var body: some View {
        let typed = app.importantSendersList
        let ruled = app.senderRules.rules.filter { $0.action == .important }
        VStack(alignment: .leading, spacing: 6) {
            Text("Important senders").font(.body)
            if typed.isEmpty && ruled.isEmpty {
                Text("None yet. They get a notification for new mail and always come first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(typed, id: \.self) { sender in
                row(sender, detail: nil) { app.removeImportantSender(sender) }
            }
            ForEach(ruled) { rule in
                row(rule.name.map { "\($0) <\(rule.key)>" } ?? rule.key, detail: "from /triage") { app.senderRules.remove(rule.key) }
            }
            HStack {
                TextField("Address, @domain or name", text: $newSender)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newSender.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func row(_ text: String, detail: String?, remove: @escaping () -> Void) -> some View {
        HStack {
            Text(text).lineLimit(1)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Remove", systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private func add() {
        app.addImportantSender(newSender)
        newSender = ""
    }
}

private struct WeatherSettingsSection: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var message: String?

    var body: some View {
        Section {
            if let place = app.weather.place {
                HStack {
                    Text("\(place.name), \(place.country)")
                    Spacer()
                    Button("Remove") { app.weather.choose(nil) }
                }
            }
            HStack {
                TextField("Search a place", text: $query, prompt: Text("e.g. Morlaix"))
                    .onSubmit(search)
                Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(results, id: \.self) { place in
                Button("\(place.name), \(place.country)") {
                    app.weather.choose(place)
                    results = []
                    query = ""
                }
                .buttonStyle(.borderless)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Weather")
        } footer: {
            Text("""
                From Open-Meteo (free, no account; non-commercial use). Only the chosen place's coordinates are sent — \
                not your Mac's location. Used by /weather and the Weather widget in the right panel.
                """)
            .foregroundStyle(.secondary)
        }
    }

    private func search() {
        let name = query
        Task {
            do {
                results = try await app.weather.search(name)
                message = results.isEmpty ? "No place found." : nil
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct LearningSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var learning = app.learning
        Section {
            TextField("Explain cards and corrections in", text: $learning.explainIn, prompt: Text("e.g. German"))
            let languages = learning.deck.languages
            LabeledContent("Cards") {
                Text(languages.isEmpty ? "none yet" : languages.map { language in
                    "\(language) \(learning.deck.cards.filter { $0.language == language }.count)"
                }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            }
            Button("Show Cards File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppData.flashcards]) }
        } header: {
            Text("Languages")
        } footer: {
            Text("/spelling checks a text (macOS spell checker + your local model), /flashcard makes a card, /learn reviews due cards first. Everything stays on this Mac.")
                .foregroundStyle(.secondary)
        }
    }
}
