import Persistence
import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var draft = ""
    @State private var viewportHeight: CGFloat = 0

    private var isStreaming: Bool { app.chat.isStreaming(conversation) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                let messages = conversation.orderedMessages
                ForEach(messages) { message in
                    MessageRow(message: message, isStreaming: isStreaming && message == messages.last)
                }
            }
            .padding(20)
            .frame(maxWidth: 820)
            // Short transcripts sit at the bottom but still fill the viewport, so no content edge
            // (and no scroll-edge separator) appears mid-window.
            .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .bottom)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
