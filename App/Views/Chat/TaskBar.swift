import Persistence
import Routing
import SwiftUI

/// Task, model and (for translation) target language of the next turn.
struct TaskBar: View {
    @Bindable var conversation: Conversation
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(TaskKind.allCases) { task in
                    Button(task.title, systemImage: task.systemImage) {
                        app.select(task, for: conversation)
                    }
                }
            } label: {
                Label(conversation.task.title, systemImage: conversation.task.systemImage)
            }
            .help("Task (⌘1–⌘4)")

            modelMenu

            if conversation.task == .translate {
                Picker("Into", selection: targetLanguage) {
                    ForEach(Languages.common, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }

            Spacer()
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(.callout)
        .padding(.horizontal, 12)
    }

    private var modelMenu: some View {
        let taskModel = app.taskProfiles[conversation.task].modelID
        return Menu {
            Button("Task Default (\(taskModel))") {
                conversation.providerOverride = nil
                conversation.modelOverride = nil
            }
            Divider()
            ForEach(app.models) { model in
                Button(model.displayName) {
                    conversation.providerOverride = app.ollama.id.rawValue
                    conversation.modelOverride = model.id
                }
            }
        } label: {
            Label(app.effectiveModel(for: conversation), systemImage: conversation.modelOverride == nil ? "cpu" : "cpu.fill")
        }
        .fixedSize()
        .help(conversation.modelOverride == nil
            ? "Model mapped to \(conversation.task.title) in Settings"
            : "Overridden for this conversation")
    }

    private var targetLanguage: Binding<String> {
        Binding(
            get: { app.targetLanguage(for: conversation) },
            set: { conversation.targetLanguage = $0 }
        )
    }
}
