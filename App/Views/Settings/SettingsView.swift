import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Tasks", systemImage: "square.stack.3d.up") {
                TaskSettings()
            }
        }
        .frame(width: 600)
        .task { await app.refreshModels() }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section("Ollama") {
                TextField("Server", text: $app.ollamaHost, prompt: Text("http://localhost:11434"))
                LabeledContent("Status") {
                    if app.isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else if let error = app.modelsError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("\(app.models.count) models available").foregroundStyle(.secondary)
                    }
                }
                Button("Test Connection") {
                    Task { await app.refreshModels() }
                }
            }
        }
        .formStyle(.grouped)
    }
}
