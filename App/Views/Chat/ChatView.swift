import Commands
import Persistence
import SwiftData
import SwiftUI

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var draft = ""
    @State private var suggestionIndex = 0
    @State private var suggestionsDismissed = false
    @State private var commandError: String?
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
            VStack(alignment: .leading, spacing: 0) {
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
                    .padding(.top, 8)
                }
                ComposerResizeHandle(height: $composerHeight, maxHeight: max(Composer.minHeight, viewportHeight * 0.6))
                TaskBar(conversation: conversation)
                    .padding(.bottom, 8)
                let suggestions = completion.suggestions
                if !suggestions.isEmpty {
                    CommandSuggestions(commands: suggestions, selected: min(suggestionIndex, suggestions.count - 1)) { accept($0) }
                } else if let note = commandError ?? completion.argumentHint {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(commandError == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.field)
                        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
                }
                Composer(
                    text: $draft,
                    height: composerHeight,
                    isStreaming: isStreaming,
                    suggestionCount: suggestions.count,
                    onSuggestionMove: { delta in
                        suggestionIndex = (suggestionIndex + delta + suggestions.count) % max(suggestions.count, 1)
                    },
                    onSuggestionAccept: {
                        let pick = suggestions[min(suggestionIndex, suggestions.count - 1)]
                        // Return on an already complete name runs it instead of re-completing.
                        guard draft.trimmingCharacters(in: .whitespaces) != "/\(pick.name)" else { return false }
                        accept(pick)
                        return true
                    },
                    onSuggestionDismiss: { suggestionsDismissed = true },
                    onSend: send
                ) {
                    app.chat.stop(conversation)
                }
            }
            .background(Theme.header)
            .overlay(alignment: .top) { Theme.border.frame(height: 1) }
        }
        .onChange(of: draft) { _, text in
            suggestionIndex = 0
            commandError = nil
            if !text.hasPrefix("/") { suggestionsDismissed = false }
        }
        .navigationTitle(conversation.title)
        .focusedSceneValue(\.activeConversation, conversation)
    }

    private var completion: CommandCompletion {
        CommandCompletion(registry: app.commands.registry, text: draft, dismissed: suggestionsDismissed)
    }

    private func accept(_ command: CommandSpec) {
        draft = CommandCompletion.accepted(command)
        suggestionsDismissed = false
    }

    private func send() {
        if let outcome = app.runCommand(draft, in: conversation, context: context, onRedirect: { app.requestedConversation = $0.persistentModelID }) {
            if case .failed(let message) = outcome {
                commandError = message
                return
            }
            draft = ""
            return
        }
        app.send(draft, in: conversation, context: context)
        draft = ""
    }
}
