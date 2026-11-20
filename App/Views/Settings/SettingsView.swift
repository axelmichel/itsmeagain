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
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }
}
