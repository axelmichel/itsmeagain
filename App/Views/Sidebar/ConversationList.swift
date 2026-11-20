import Persistence
import SwiftData
import SwiftUI

/// Flat conversation list (Zed-style): header row under the traffic lights, search, and rows with a
/// neutral grey selection. ↑/↓ move the selection, ⌫ deletes.
struct ConversationList: View {
    @Binding var selection: Conversation?
    let onNew: () -> Void
    let onToggleSidebar: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var search = ""
    @FocusState private var listFocused: Bool

    private var filtered: [Conversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                HeaderButton("Hide Sidebar", systemImage: "sidebar.left", action: onToggleSidebar)
                HeaderButton("New Chat", systemImage: "square.and.pencil", action: onNew)
            }
            .padding(.horizontal, 12)
            .headerBar()

            // Full-width search row directly under the header bar.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Theme.field)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { conversation in
                        ConversationRow(conversation: conversation, isSelected: conversation == selection) {
                            selection = conversation
                            listFocused = true
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete(conversation) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(by: -1) }
            .onKeyPress(.downArrow) { move(by: 1) }
            .onDeleteCommand {
                if let selection { delete(selection) }
            }
        }
        .background(Theme.sidebar)
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let list = filtered
        guard !list.isEmpty else { return .ignored }
        let index = selection.flatMap { list.firstIndex(of: $0) } ?? (offset > 0 ? -1 : list.count)
        selection = list[min(max(index + offset, 0), list.count - 1)]
        return .handled
    }

    private func delete(_ conversation: Conversation) {
        app.chat.discard(conversation)
        if selection == conversation { selection = nil }
        context.delete(conversation)
        try? context.save()
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .lineLimit(1)
                Text(conversation.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.selection : hovered ? Theme.hover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(conversation.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
