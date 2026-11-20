import AppKit
import Observation
import Persistence
import Routing
import SwiftData
import SwiftUI

/// Quick panel mode: Auto routing or a fixed task.
enum QuickMode: Hashable {
    case auto
    case task(TaskKind)

    var rawValue: String {
        switch self {
        case .auto: "auto"
        case .task(let task): task.rawValue
        }
    }

    init(rawValue: String) {
        self = TaskKind(rawValue: rawValue).map(QuickMode.task) ?? .auto
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .task(let task): task.title
        }
    }

    var systemImage: String {
        switch self {
        case .auto: "wand.and.sparkles"
        case .task(let task): task.systemImage
        }
    }
}

@MainActor
@Observable
final class QuickPanelState {
    var draft = ""
    /// The chat the panel is continuing; follow-ups go here until "New" or "Open in ItsMeAgain".
    var conversation: Conversation?
    var mode = QuickMode(rawValue: UserDefaults.standard.string(forKey: "quickMode") ?? "auto") {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "quickMode") }
    }
    var targetLanguage = ""
    var focusRequest = 0

    func prepareForShowing(app: AppModel) {
        if conversation?.isDeleted == true { conversation = nil }
        if targetLanguage.isEmpty { targetLanguage = app.defaultTargetLanguage }
        // Translate starts from the clipboard, but never sends on its own.
        if mode == .task(.translate), conversation == nil, draft.isEmpty,
            let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        {
            draft = String(clipboard.prefix(5_000))
        }
    }
}

struct QuickPanelView: View {
    @Bindable var state: QuickPanelState
    let onClose: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @FocusState private var focused: Bool
    @State private var answerHeight: CGFloat = 0

    private var isStreaming: Bool {
        state.conversation.map { app.chat.isStreaming($0) } ?? false
    }

    private var lastExchange: (question: StoredMessage?, reply: StoredMessage)? {
        guard let messages = state.conversation?.orderedMessages, let reply = messages.last, reply.role == .assistant else {
            return nil
        }
        return (messages.dropLast().last, reply)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: state.mode.systemImage)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(send)
                if isStreaming {
                    ProgressView().controlSize(.small)
                }
            }

            toolbar

            if let exchange = lastExchange {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let question = exchange.question {
                            Text(question.content)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        MessageRow(message: exchange.reply, isStreaming: isStreaming)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
                }
                .defaultScrollAnchor(.bottom)
                // As tall as the answer, up to a limit; then it scrolls.
                .frame(height: min(max(answerHeight, 20), 380))
            }
        }
        .padding(16)
        .frame(width: 640)
        .background(Theme.header)
        // The hidden title bar would otherwise reserve space above the field.
        .ignoresSafeArea()
        .onChange(of: state.focusRequest, initial: true) { focused = true }
        .onExitCommand(perform: onClose)
    }

    private var placeholder: String {
        state.mode == .task(.translate) ? "Text to translate…" : "Ask anything…"
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Menu {
                Button(QuickMode.auto.title, systemImage: QuickMode.auto.systemImage) { setMode(.auto) }
                Divider()
                ForEach(TaskKind.allCases) { task in
                    Button(task.title, systemImage: task.systemImage) { setMode(.task(task)) }
                }
            } label: {
                Label(state.mode.title, systemImage: state.mode.systemImage)
            }
            .fixedSize()

            if state.mode == .task(.translate) || state.mode == .auto {
                LanguageMenu(selection: $state.targetLanguage)
                .onChange(of: state.targetLanguage) { state.conversation?.targetLanguage = state.targetLanguage }
            }

            Spacer()

            if let conversation = state.conversation {
                if let reply = lastExchange?.reply, !reply.content.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reply.content, forType: .string)
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                Button("New", systemImage: "square.and.pencil") {
                    state.conversation = nil
                    state.draft = ""
                    focused = true
                }
                .keyboardShortcut("n")
                Button("Open in ItsMeAgain", systemImage: "arrow.up.forward.app") { openInMainWindow(conversation) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func setMode(_ mode: QuickMode) {
        state.mode = mode
        guard let conversation = state.conversation else { return }
        switch mode {
        case .auto: app.selectAuto(for: conversation)
        case .task(let task): app.select(task, for: conversation)
        }
    }

    private func send() {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let conversation: Conversation
        if let current = state.conversation, !current.isDeleted {
            conversation = current
        } else {
            switch state.mode {
            case .auto: conversation = Conversation(task: app.lastTask, autoRoute: true)
            case .task(let task): conversation = Conversation(task: task)
            }
            conversation.targetLanguage = state.targetLanguage
            context.insert(conversation)
            state.conversation = conversation
        }
        app.send(text, in: conversation, context: context)
        state.draft = ""
    }

    private func openInMainWindow(_ conversation: Conversation) {
        app.requestedConversation = conversation.persistentModelID
        app.openMainWindow()
        state.conversation = nil
        onClose()
    }
}
