import Persistence
import Routing
import SwiftData
import SwiftUI

/// Flat conversation list (Zed-style): header row under the traffic lights, search, and the history
/// grouped into collapsible sections per mode (Chat, Translate, Research, Code). Auto conversations
/// sit under the task of their latest message. ↑/↓ move through visible rows, ⌫ deletes.
struct ConversationList: View {
    @Binding var selection: Conversation?
    let onNew: () -> Void
    let onToggleSidebar: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var search = ""
    @FocusState private var listFocused: Bool
    /// Comma-separated raw values of collapsed sections.
    @AppStorage("collapsedHistorySections") private var collapsedRaw = ""

    private var filtered: [Conversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedStandardContains(search) }
    }

    private var sections: [(task: TaskKind, conversations: [Conversation])] {
        let list = filtered
        return TaskKind.allCases.compactMap { task in
            let items = list.filter { $0.task == task }
            return items.isEmpty ? nil : (task, items)
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    /// Rows in display order, skipping collapsed sections (search always shows everything).
    private var visibleRows: [Conversation] {
        sections.flatMap { section in
            isCollapsed(section.task) ? [] : section.conversations
        }
    }

    private func isCollapsed(_ task: TaskKind) -> Bool {
        search.isEmpty && collapsed.contains(task.rawValue)
    }

    private func toggle(_ task: TaskKind) {
        var set = collapsed
        if set.contains(task.rawValue) { set.remove(task.rawValue) } else { set.insert(task.rawValue) }
        collapsedRaw = set.sorted().joined(separator: ",")
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
                    ForEach(sections, id: \.task) { section in
                        SectionHeader(
                            task: section.task,
                            count: section.conversations.count,
                            isCollapsed: isCollapsed(section.task)
                        ) { toggle(section.task) }
                        if !isCollapsed(section.task) {
                            ForEach(section.conversations) { conversation in
                                ConversationRow(conversation: conversation, isSelected: conversation == selection) {
                                    selection = conversation
                                    listFocused = true
                                }
                                .contextMenu {
                                    Button("Delete", role: .destructive) { delete(conversation) }
                                }
                            }
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
        let list = visibleRows
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

/// Dim, Zed-like group heading; click to collapse or expand.
private struct SectionHeader: View {
    let task: TaskKind
    let count: Int
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Image(systemName: task.systemImage)
                    .font(.caption)
                Text(task.title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("\(task.title), \(count) conversations, \(isCollapsed ? "collapsed" : "expanded")")
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
                HStack(spacing: 4) {
                    if conversation.autoRoute {
                        Image(systemName: "wand.and.sparkles")
                            .help("Auto: filed under the task of its latest message")
                    }
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26)
            .padding(.trailing, 10)
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
