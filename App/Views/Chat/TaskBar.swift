import Persistence
import Routing
import SwiftUI

/// Task (or Auto) and, for translation, the target language of the next turn. The model always comes
/// from the task mapping in Settings → Tasks.
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

            if conversation.task == .translate || conversation.autoRoute {
                LanguageMenu(selection: targetLanguage)
            }

            Spacer()
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(.callout)
        .padding(.horizontal, 12)
    }

    private var targetLanguage: Binding<String> {
        Binding(
            get: { app.targetLanguage(for: conversation) },
            set: { conversation.targetLanguage = $0 }
        )
    }
}
