import AppleIntelligence
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
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
        .frame(height: 560)
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
