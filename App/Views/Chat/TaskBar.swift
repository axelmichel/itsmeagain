import Persistence
import Routing
import SwiftUI

/// Task (or Auto), model and (for translation) target language of the next turn.
struct TaskBar: View {
    @Bindable var conversation: Conversation
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Button("Auto", systemImage: "wand.and.sparkles") { app.selectAuto(for: conversation) }
                Divider()
                ForEach(TaskKind.allCases) { task in
                    Button(task.title, systemImage: task.systemImage) {
                        app.select(task, for: conversation)
                    }
                }
            } label: {
                if conversation.autoRoute {
                    Label("Auto", systemImage: "wand.and.sparkles")
                } else {
                    Label(conversation.task.title, systemImage: conversation.task.systemImage)
                }
            }
            .help(conversation.autoRoute
                ? "Each message is routed to Chat, Translate, Research or Code (⌘0–⌘4)"
                : "Task (⌘0–⌘4)")

            modelMenu

            if conversation.task == .translate || conversation.autoRoute {
                Picker("Into", selection: targetLanguage) {
                    ForEach(Languages.common, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                .help("Target language for translations")
            }

            Spacer()
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(.callout)
        .padding(.horizontal, 12)
    }

    private var modelMenu: some View {
        let current = app.effectiveModel(for: conversation)
        let overridden = conversation.modelOverride != nil
        return Menu {
            if overridden {
                Button("Use \(conversation.task.title) Mapping") {
                    conversation.providerOverride = nil
                    conversation.modelOverride = nil
                }
                Divider()
            }
            ForEach(app.enabledProviders) { config in
                if let models = app.models[config.id], !models.isEmpty {
                    Section(config.name) {
                        ForEach(models) { model in
                            Button(model.displayName) {
                                conversation.providerOverride = config.id.rawValue
                                conversation.modelOverride = model.id
                            }
                        }
                    }
                }
            }
        } label: {
            Label(label(for: current), systemImage: app.config(for: current.provider)?.systemImage ?? "cpu")
        }
        .fixedSize()
        .help(help(overridden: overridden))
    }

    private func label(for ref: ModelRef) -> String {
        app.models[ref.provider]?.first { $0.id == ref.model }?.displayName ?? ref.model
    }

    private func help(overridden: Bool) -> String {
        if overridden { return "Model chosen for this conversation" }
        if conversation.autoRoute { return "Model mapped to the last routed task (\(conversation.task.title))" }
        return "Model mapped to \(conversation.task.title) in Settings → Tasks"
    }

    private var targetLanguage: Binding<String> {
        Binding(
            get: { app.targetLanguage(for: conversation) },
            set: { conversation.targetLanguage = $0 }
        )
    }
}
