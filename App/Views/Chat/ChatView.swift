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

            VStack(alignment: .leading, spacing: 4) {
                TaskBar(conversation: conversation)
                Composer(text: $draft, isStreaming: isStreaming, onSend: send) {
                    app.chat.stop(conversation)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle(conversation.title)
        .focusedSceneValue(\.activeConversation, conversation)
    }

    private func send() {
        app.send(draft, in: conversation, context: context)
        draft = ""
    }
}
