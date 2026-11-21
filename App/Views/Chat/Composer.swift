import AppKit
import SwiftUI

/// Multi-line message editor. Return sends, Shift/Option-Return inserts a newline, ⌘Return also sends.
/// While a reply is running, sending queues the message.
struct Composer: View {
    static let defaultHeight = 110.0
    static let minHeight = 44.0

    @Binding var text: String
    let height: Double
    let isStreaming: Bool
    /// Number of visible `/` suggestions; when > 0, ↑/↓/Tab/Return/Esc drive the list.
    var suggestionCount = 0
    var onSuggestionMove: (Int) -> Void = { _ in }
    /// Returns true if a suggestion was inserted (Return then doesn't send).
    var onSuggestionAccept: () -> Bool = { false }
    var onSuggestionDismiss: () -> Void = {}
    let onSend: () -> Void
    let onStop: () -> Void
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down, action: handleReturn)
                    .onKeyPress(.upArrow) { suggestionKey { onSuggestionMove(-1) } }
                    .onKeyPress(.downArrow) { suggestionKey { onSuggestionMove(1) } }
                    .onKeyPress(.tab) { suggestionCount > 0 && onSuggestionAccept() ? .handled : .ignored }
                    .onKeyPress(.escape) { suggestionKey(onSuggestionDismiss) }
                if text.isEmpty {
                    Text("Message")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: height)

            VStack(spacing: 6) {
                if isStreaming {
                    Button("Stop", systemImage: "stop.circle.fill", action: onStop)
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop the reply (⌘.); queued messages wait until you resume")
                }
                Button(isStreaming ? "Queue" : "Send", systemImage: isStreaming ? "text.badge.plus" : "arrow.up.circle.fill", action: onSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
                    .help(isStreaming ? "Queue — sent after the current reply" : "Send (Return)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title2)
        }
        // Full-width editor area; only a line separates it from the task bar.
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.field)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
        .onAppear { focused = true }
    }

    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        // Newline on Shift/Option-Return, and let input methods confirm marked text (e.g. Japanese).
        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
        if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
        if suggestionCount > 0 && onSuggestionAccept() { return .handled }
        if canSend { onSend() }
        return .handled
    }

    private func suggestionKey(_ action: () -> Void) -> KeyPress.Result {
        guard suggestionCount > 0 else { return .ignored }
        action()
        return .handled
    }
}

/// Drag to resize the composer; double-click to reset.
struct ComposerResizeHandle: View {
    @Binding var height: Double
    let maxHeight: Double
    @State private var startHeight: Double?

    var body: some View {
        Rectangle()
            .fill(.tertiary)
            .frame(width: 36, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .top))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startHeight ?? height
                        startHeight = start
                        height = min(max(start - value.translation.height, Composer.minHeight), maxHeight)
                    }
                    .onEnded { _ in startHeight = nil }
            )
            .onTapGesture(count: 2) { height = Composer.defaultHeight }
            .help("Drag to resize the message editor; double-click to reset")
    }
}
