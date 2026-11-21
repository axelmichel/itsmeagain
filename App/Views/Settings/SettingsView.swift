import AppleIntelligence
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Assistant", systemImage: "person.crop.circle") {
                AssistantSettings()
            }
            Tab("Providers", systemImage: "server.rack") {
                ProviderSettings()
            }
            Tab("Tasks", systemImage: "square.stack.3d.up") {
                TaskSettings()
            }
            Tab("Knowledge", systemImage: "books.vertical") {
                KnowledgeSettings()
            }
            Tab("Commands", systemImage: "command") {
                CommandSettings()
            }
        }
        .frame(width: 620)
        .task { await app.refreshModels() }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                OpenAtLoginToggle()
            } header: {
                Text("App")
            } footer: {
                Text("Keeps the quick panel and automations available. Install the app in /Applications first (make install).")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Notify me when a long task is done", isOn: $app.notifyWhenDone)
                if app.notifyWhenDone {
                    Picker("For tasks longer than", selection: $app.notifyAfterSeconds) {
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("3 minutes").tag(180)
                    }
                    Toggle("Show a preview of the answer", isOn: $app.notifyWithPreview)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("""
                    A macOS notification when a reply or command (e.g. /digest, /cleanup) finishes or fails — not while \
                    you're looking at that conversation, not when you stopped it, and not for automations (they notify \
                    on their own). Click it to open the conversation.
                    """)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: $app.quickPanelShortcut) { app.suspendHotKey($0) }
                }
                if !app.hotKeyRegistered {
                    Text("This shortcut is taken by another app or macOS. Choose a different one.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Toggle("Show in Menu Bar", isOn: $app.showMenuBarIcon)
            } header: {
                Text("Quick Panel")
            } footer: {
                Text("Opens a floating panel from anywhere for a quick question or translation. Translate pre-fills the clipboard.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use Apple Intelligence when available", isOn: $app.preferAppleRouter)
                if let reason = AppleOnDeviceProvider.unavailableReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ModelPicker(title: "Classifier Model", selection: $app.routerModel)
                    .disabled(app.preferAppleRouter && app.appleRouterAvailable)
            } header: {
                Text("Auto Routing")
            } footer: {
                Text("""
                    In Auto mode each message goes to Chat, Translate, Research or Code. Obvious cases \
                    (code blocks, "translate …") are routed instantly; the rest is classified by the \
                    on-device model or, if that is unavailable, the classifier model. A small, fast model works best.
                    """)
                .foregroundStyle(.secondary)
            }

            WebSearchSection()
        }
        .formStyle(.grouped)
        .frame(height: 860)
    }
}

private struct WebSearchSection: View {
    @Environment(AppModel.self) private var app
    @State private var apiKey = ""
    @State private var loadedFor: SearchBackendKind?

    var body: some View {
        @Bindable var app = app
        Section {
            Picker("Search With", selection: $app.searchBackend) {
                ForEach(SearchBackendKind.allCases) { Text($0.title).tag($0) }
            }
            switch app.searchBackend {
            case .searxng:
                TextField("SearXNG URL", text: $app.searxngURL, prompt: Text("http://localhost:8888"))
            case .brave, .ollama:
                SecureField("API Key", text: $apiKey)
                    .onChange(of: apiKey) { _, key in
                        if loadedFor == app.searchBackend { KeychainStore.setKey(key, for: app.searchBackend.keychainAccount) }
                    }
            case .wikipedia:
                EmptyView()
            }
        } header: {
            Text("Web Search")
        } footer: {
            Text(footer).foregroundStyle(.secondary)
        }
        .onChange(of: app.searchBackend, initial: true) { _, backend in
            loadedFor = nil
            apiKey = backend.needsAPIKey ? KeychainStore.key(for: backend.keychainAccount) ?? "" : ""
            loadedFor = backend
        }
    }

    private var footer: String {
        switch app.searchBackend {
        case .wikipedia:
            "Works without setup but only searches Wikipedia, which is weak for news, products and ambiguous names. Use SearXNG or an API for real web search."
        case .searxng:
            "Self-hosted metasearch engine (e.g. Docker, reachable via Tailscale). Its settings.yml must allow the json format. Falls back to Wikipedia when unreachable."
        case .brave:
            "Get a key at brave.com/search/api (free tier available). Stored in the Keychain. Falls back to Wikipedia on errors."
        case .ollama:
            "Uses an ollama.com API key. Stored in the Keychain. Falls back to Wikipedia on errors."
        }
    }
}

private struct OpenAtLoginToggle: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at Login", isOn: Binding(
                get: { enabled },
                set: { value in
                    do {
                        try LoginItem.set(value)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                    enabled = LoginItem.isEnabled
                }
            ))
            if LoginItem.needsApproval {
                Text("Approve ItsMeAgain in System Settings → General → Login Items.")
                    .font(.callout).foregroundStyle(.orange)
            } else if !LoginItem.runsFromApplications {
                Text("This copy runs from \(Bundle.main.bundleURL.deletingLastPathComponent().path); it would be registered from there.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }
}
