import Persistence
import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var draft = ""
    @State private var viewportHeight: CGFloat = 0
    @AppStorage("composerHeight") private var composerHeight = Composer.defaultHeight

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
        .background(Theme.canvas)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                let queued = app.chat.queue(for: conversation)
                if !queued.isEmpty {
                    QueuedMessagesView(
                        messages: queued,
                        isPaused: app.chat.isQueuePaused(conversation),
                        onEdit: { message in
                            app.chat.removeQueued(message.id, from: conversation)
                            draft = draft.isEmpty ? message.text : message.text + "\n\n" + draft
                        },
                        onRemove: { app.chat.removeQueued($0.id, from: conversation) },
                        onResume: { app.chat.resume(conversation) }
                    )
                }
                ComposerResizeHandle(height: $composerHeight, maxHeight: max(Composer.minHeight, viewportHeight * 0.6))
                TaskBar(conversation: conversation)
                Composer(text: $draft, height: composerHeight, isStreaming: isStreaming, onSend: send) {
                    app.chat.stop(conversation)
                }
            }
            .background(Theme.panel)
            .overlay(alignment: .top) { Theme.border.frame(height: 1) }
        }
        .navigationTitle(conversation.title)
        .focusedSceneValue(\.activeConversation, conversation)
    }

    private func send() {
        app.send(draft, in: conversation, context: context)
        draft = ""
    }
}
