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
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var matchIndex = 0
    @FocusState private var findFocused: Bool

    private var isStreaming: Bool { app.chat.isStreaming(conversation) }

    private var matches: [StoredMessage] {
        findVisible ? conversation.messages(matching: findQuery) : []
    }

    private var currentMatch: StoredMessage? {
        let all = matches
        return all.isEmpty ? nil : all[min(matchIndex, all.count - 1)]
    }

    @ViewBuilder
    private var rows: some View {
        let messages = conversation.orderedMessages
        let current = currentMatch
        ForEach(messages) { message in
            MessageRow(
                message: message,
                isStreaming: isStreaming && message == messages.last,
                onDelete: isStreaming ? nil : { withAnswer in delete(message, withAnswer: withAnswer) },
                isCurrentMatch: message == current
            )
            .id(message.id)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack inside the bottom-aligned, viewport-high frame below kept
                // re-estimating row heights against the frame and looped forever (frozen app) when a
                // tall card or a live progress line moved the content height across the viewport.
                VStack(alignment: .leading, spacing: 18) { rows }
                .padding(20)
                .frame(maxWidth: 820)
                // Short transcripts sit at the bottom but still fill the viewport, so no content edge
                // (and no scroll-edge separator) appears mid-window.
                .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .bottom)
            }
            .environment(\.searchHighlight, findVisible ? findQuery : nil)
            .onChange(of: currentMatch?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if findVisible { findBar }
        }
        .background {
            Group {
                Button("Find") { showFind() }.keyboardShortcut("f")
                Button("Find Next") { step(1) }.keyboardShortcut("g")
                Button("Find Previous") { step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .hidden()
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
        .onAppear { app.visibleConversation = conversation.persistentModelID }
        .onDisappear {
            if app.visibleConversation == conversation.persistentModelID { app.visibleConversation = nil }
        }
        .focusedSceneValue(\.activeConversation, conversation)
    }

    // MARK: Find

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Find in conversation", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($findFocused)
                .onSubmit { step(1) }
                .onKeyPress(.escape) {
                    closeFind()
                    return .handled
                }
            let count = matches.count
            if !findQuery.isEmpty {
                Text(count == 0 ? "No matches" : "\(min(matchIndex, count - 1) + 1) of \(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Group {
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G or Return)")
            }
            .disabled(count < 2)
            Button("Done", action: closeFind)
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.field)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
        .onChange(of: findQuery) {
            // Start at the newest match: that's usually what you're looking for.
            matchIndex = max(matches.count - 1, 0)
        }
    }

    private func showFind() {
        findVisible = true
        findFocused = true
    }

    private func closeFind() {
        findVisible = false
        findQuery = ""
    }

    private func step(_ direction: Int) {
        guard findVisible else { return showFind() }
        let count = matches.count
        guard count > 0 else { return }
        matchIndex = (min(matchIndex, count - 1) + direction + count) % count
    }

    // MARK: Editing

    private func delete(_ message: StoredMessage, withAnswer: Bool) {
        for item in conversation.deletion(of: message, withAnswer: withAnswer) {
            conversation.messages.removeAll { $0.id == item.id }
            context.delete(item)
        }
        try? context.save()
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
