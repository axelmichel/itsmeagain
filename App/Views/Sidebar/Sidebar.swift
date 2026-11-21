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
                if app.sidebarMode == .chats {
                    HeaderButton("New Chat", systemImage: "square.and.pencil", action: onNewChat)
                } else {
                    HeaderButton("New Automation", systemImage: "plus", action: onNewAutomation)
                }
            }
            .padding(.horizontal, 12)
            .headerBar()

            HStack(spacing: 0) {
                modeButton("Chats", mode: .chats)
                modeButton("Automations", mode: .automations)
            }
            .frame(height: 30)
            .background(Theme.sidebar)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            switch app.sidebarMode {
            case .chats: ConversationList(selection: $conversation)
            case .automations: AutomationList(selection: $automation)
            }
        }
        .background(Theme.sidebar)
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
