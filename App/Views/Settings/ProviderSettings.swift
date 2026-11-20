import CompanionCore
import SwiftUI

/// Add, configure and test model providers. API keys go straight to the Keychain.
struct ProviderSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            ForEach($app.providers) { $config in
                ProviderSection(config: $config)
            }

            Section {
                HStack {
                    Menu("Add Provider", systemImage: "plus") {
                        ForEach(ProviderConfig.presets) { preset in
                            Button(preset.name) { app.addProvider(preset) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if app.isLoadingModels { ProgressView().controlSize(.small) }
                    Button("Refresh Models") {
                        Task { await app.refreshModels() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
    }
}

private struct ProviderSection: View {
    @Binding var config: ProviderConfig
    @Environment(AppModel.self) private var app
    @State private var apiKey = ""
    @State private var loadedKey = false

    var body: some View {
        Section {
            if config.kind != .appleIntelligence && config.kind != .appleTranslation {
                TextField("Name", text: $config.name)
                TextField("Server", text: $config.baseURL, prompt: Text("https://…"))
                    .onSubmit(refresh)
            }
            if config.needsAPIKey {
                SecureField("API Key", text: $apiKey, prompt: Text(config.isLocal ? "Optional" : "Required"))
                    .onSubmit(refresh)
                    .onChange(of: apiKey) { _, key in
                        if loadedKey { KeychainStore.setKey(key, for: config.id.rawValue) }
                    }
            }
            LabeledContent("Status") { status }
            if !config.isBuiltIn {
                Button("Remove \(config.name)", role: .destructive) {
                    app.removeProvider(config.id)
                }
            }
        } header: {
            HStack {
                Label(config.name, systemImage: config.systemImage)
                Text(config.isLocal ? "Local" : "Cloud")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: .capsule)
                Spacer()
                Toggle("Enabled", isOn: $config.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: config.enabled) { refresh() }
            }
        }
        .onAppear {
            guard !loadedKey else { return }
            apiKey = config.needsAPIKey ? KeychainStore.key(for: config.id.rawValue) ?? "" : ""
            loadedKey = true
        }
    }

    @ViewBuilder
    private var status: some View {
        if !config.enabled {
            Text("Disabled").foregroundStyle(.secondary)
        } else if let error = app.modelErrors[config.id] {
            Text(error).foregroundStyle(.red).multilineTextAlignment(.trailing)
        } else if let models = app.models[config.id] {
            Text(models.count == 1 ? "Ready" : "\(models.count) models").foregroundStyle(.secondary)
        } else {
            Text("Not checked").foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        Task { await app.refreshModels() }
    }
}
