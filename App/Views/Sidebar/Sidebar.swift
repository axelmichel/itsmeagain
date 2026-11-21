import Memory
import Persistence
import SwiftUI

/// Sidebar: header row (under the traffic lights), Chats | Automations switch, and the list.
struct Sidebar: View {
    @Binding var conversation: Conversation?
    @Binding var automation: Automation?
    let onNewChat: () -> Void
    let onNewAutomation: () -> Void
    let onToggleSidebar: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                HeaderButton("Hide Sidebar", systemImage: "sidebar.left", action: onToggleSidebar)
                switch app.sidebarMode {
                case .chats: HeaderButton("New Chat", systemImage: "square.and.pencil", action: onNewChat)
                case .automations: HeaderButton("New Automation", systemImage: "plus", action: onNewAutomation)
                case .memory: EmptyView()
                }
            }
            .padding(.horizontal, 12)
            .headerBar()

            HStack(spacing: 0) {
                modeButton("Chats", mode: .chats)
                modeButton("Automations", mode: .automations)
                modeButton(memoryTitle, mode: .memory)
            }
            .frame(height: 30)
            .background(Theme.sidebar)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            switch app.sidebarMode {
            case .chats: ConversationList(selection: $conversation)
            case .automations: AutomationList(selection: $automation)
            case .memory: MemorySidebar()
            }
        }
        .background(Theme.sidebar)
    }

    private var memoryTitle: String {
        let pending = app.memory.book.pending.count
        return pending > 0 ? "Memory (\(pending))" : "Memory"
    }

    private func modeButton(_ title: String, mode: AppModel.SidebarMode) -> some View {
        let active = app.sidebarMode == mode
        return Button {
            app.sidebarMode = mode
        } label: {
            Text(title)
                .font(.callout.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if active { Theme.accent.frame(height: 2) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// Counts per kind; the Memory page itself is in the detail area.
private struct MemorySidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let book = app.memory.book
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !book.pending.isEmpty {
                    row("To review", count: book.pending.count, systemImage: "tray", accent: true)
                }
                ForEach(MemoryKind.allCases) { kind in
                    row(kind.title, count: book.active.filter { $0.kind == kind }.count, systemImage: "circle.fill", accent: false)
                }
                Text("Only your own Chat messages are read, only on this Mac, and only local models ever see this.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }
            .padding(12)
        }
    }

    private func row(_ title: String, count: Int, systemImage: String, accent: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(accent ? Theme.accent : .primary)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
    }
}
