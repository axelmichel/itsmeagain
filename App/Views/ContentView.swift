import Persistence
import SwiftData
import SwiftUI

/// Flat, Zed-style layout: a plain sidebar and detail pane under one header row, no system toolbar.
struct ContentView: View {
    static let headerHeight: CGFloat = 38

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var selection: Conversation?
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 260.0

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                ConversationList(selection: $selection, onNew: newConversation, onToggleSidebar: toggleSidebar)
                    .frame(width: sidebarWidth)
                SidebarResizer(width: $sidebarWidth)
            }
            VStack(spacing: 0) {
                DetailHeader(
                    title: selection?.title ?? "ItsMeAgain",
                    showsSidebarControls: !sidebarVisible,
                    onToggleSidebar: toggleSidebar,
                    onNew: newConversation
                )
                if let selection {
                    ChatView(conversation: selection)
                        .id(selection.persistentModelID)
                } else {
                    ContentUnavailableView {
                        Label("No Conversation", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a new chat with a local model.")
                    } actions: {
                        Button("New Chat", action: newConversation)
                            .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.canvas)
                }
            }
        }
        // The title bar is hidden; the header rows take its place under the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .background {
            // Window-wide shortcuts without a toolbar.
            Group {
                Button("New Chat", action: newConversation).keyboardShortcut("n")
                Button("Toggle Sidebar", action: toggleSidebar).keyboardShortcut("s", modifiers: [.command, .control])
            }
            .hidden()
        }
        .task { await app.refreshModels() }
        .onChange(of: app.requestedConversation, initial: true) { _, id in
            guard let id, let conversation = context.model(for: id) as? Conversation else { return }
            selection = conversation
            app.requestedConversation = nil
        }
    }

    private func toggleSidebar() {
        withAnimation(.easeOut(duration: 0.15)) { sidebarVisible.toggle() }
    }

    private func newConversation() {
        // Reuse an untouched conversation instead of piling up empty ones.
        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        if let empty = all.first(where: { $0.messages.isEmpty }) {
            selection = empty
            return
        }
        let conversation = Conversation(task: app.lastTask, autoRoute: app.lastAuto)
        context.insert(conversation)
        try? context.save()
        selection = conversation
    }
}

/// Header row above the transcript: title, and sidebar controls when the sidebar is hidden.
struct DetailHeader: View {
    let title: String
    let showsSidebarControls: Bool
    let onToggleSidebar: () -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsSidebarControls {
                Spacer().frame(width: 64)  // traffic lights
                HeaderButton("Show Sidebar", systemImage: "sidebar.left", action: onToggleSidebar)
                HeaderButton("New Chat", systemImage: "square.and.pencil", action: onNew)
            }
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 12)
        .headerBar()
    }
}

struct HeaderButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            // Header buttons never take keyboard focus (no focus ring on launch).
            .focusable(false)
            .help(title)
    }
}

extension View {
    /// Header-coloured bar with a bottom border that also drags the window (the title bar is hidden).
    func headerBar() -> some View {
        frame(height: ContentView.headerHeight)
            .frame(maxWidth: .infinity)
            .background {
                Theme.header
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
            }
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }
}

/// The 1 pt line between sidebar and detail; drag to resize the sidebar.
struct SidebarResizer: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Theme.border
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(.rect)
                    .pointerStyle(.frameResize(position: .trailing))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start + value.translation.width, 180), 420)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
