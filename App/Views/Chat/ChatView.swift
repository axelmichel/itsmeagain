import Persistence
import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var draft = ""

    private var isStreaming: Bool { app.chat.isStreaming(conversation) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let messages = conversation.orderedMessages
                    ForEach(messages) { message in
                        MessageRow(message: message, isStreaming: isStreaming && message == messages.last)
                    }
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)

            Divider()

            Composer(text: $draft, isStreaming: isStreaming, onSend: send) {
                app.chat.stop(conversation)
            }
        }
        .navigationTitle(conversation.title)
        .toolbar {
            ToolbarItem {
                ModelPicker(selection: $conversation.modelID)
            }
        }
    }

    private func send() {
        app.chat.send(draft, in: conversation, using: app.ollama, context: context)
        draft = ""
    }
}

struct ModelPicker: View {
    @Binding var selection: String
    @Environment(AppModel.self) private var app

    var body: some View {
        Picker("Model", selection: $selection) {
            if !app.models.contains(where: { $0.id == selection }) {
                Text(selection).tag(selection)
            }
            ForEach(app.models) { model in
                Text(model.displayName).tag(model.id)
            }
        }
        .help(app.modelsError ?? "Model used for the next reply")
        .frame(minWidth: 180)
    }
}
