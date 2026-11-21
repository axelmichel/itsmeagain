import AppKit
import Mail
import Memory
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
                MemorySettingsSection()

            Section {
                Toggle("Create reminders without asking", isOn: $app.remindersWithoutAsking)
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
                LabeledContent("Important senders") {
                    TextField("tom@company.de, Anna Weber", text: $app.vipSenders, axis: .vertical)
                        .lineLimit(1...3)
                }
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
                minutes: new mail from important senders notifies you (one notification per sender), and appointments \
                found in mail (invitations, or text read by your local model) are checked against your calendar and \
                offered with Add / Ignore in the "Mail watch" conversation. Nothing is added without your click.
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
        } header: {
            Text("Obsidian")
        } footer: {
            Text("""
                Chat can search and read the enabled vaults and list their tasks. It writes only into the main vault: \
                lines in today's daily note, new notes in Inbox/, ticked tasks — each after your approval (or because \
                you typed /note, /capture or ticked it yourself). Nothing is deleted, renamed or overwritten, and the \
                app never commits: changes appear as uncommitted changes in your vault's git.
                """)
            .foregroundStyle(.secondary)
        }
        .onAppear { app.detectedVaults = Vault.detect() }
    }
}
