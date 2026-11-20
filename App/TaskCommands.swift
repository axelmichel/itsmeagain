import Persistence
import Routing
import SwiftUI

extension FocusedValues {
    @Entry var activeConversation: Conversation?
}

/// "Task" menu: ⌘0 Auto, ⌘1–⌘4 switch the focused conversation's task.
struct TaskCommands: Commands {
    let app: AppModel
    @FocusedValue(\.activeConversation) private var conversation

    var body: some Commands {
        CommandMenu("Task") {
            Button("Auto", systemImage: "wand.and.sparkles") {
                if let conversation { app.selectAuto(for: conversation) }
            }
            .keyboardShortcut("0")
            .disabled(conversation == nil)

            Divider()

            ForEach(Array(TaskKind.allCases.enumerated()), id: \.element) { index, task in
                Button(task.title, systemImage: task.systemImage) {
                    if let conversation { app.select(task, for: conversation) }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                .disabled(conversation == nil)
            }
        }
    }
}
