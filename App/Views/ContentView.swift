import Automation
import Persistence
import SwiftData
import SwiftUI

/// Flat, Zed-style layout: a plain sidebar and detail pane under one header row, no system toolbar.
struct ContentView: View {
    static let headerHeight: CGFloat = 38

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Conversation?
    @State private var automation: Automation?
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 260.0

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                Sidebar(
                    conversation: $selection,
                    automation: $automation,
                    onNewChat: newConversation,
                    onNewAutomation: newAutomation,
                    onToggleSidebar: toggleSidebar
                )
                .frame(width: sidebarWidth)
                SidebarResizer(width: $sidebarWidth)
            }
            VStack(spacing: 0) {
                DetailHeader(
                    title: app.sidebarMode == .memory ? "Memory"
                        : app.sidebarMode == .automations ? automation?.name ?? "Automations" : selection?.title ?? "ItsMeAgain",
                    showsSidebarControls: !sidebarVisible,
                    onToggleSidebar: toggleSidebar,
                    onNew: app.sidebarMode == .automations ? newAutomation : newConversation,
                    conversationID: selection?.persistentModelID,
                    onRename: app.sidebarMode == .chats ? selection.map { conversation in
                        { title in
                            conversation.title = title
                            try? context.save()
                        }
                    } : nil
                )
                .id(selection?.persistentModelID)
                if app.sidebarMode == .memory {
                    MemoryPage()
                } else if app.sidebarMode == .automations {
                    if let automation {
                        AutomationEditor(automation: automation, onDelete: deleteAutomation, onOpenConversation: openConversation)
                            .id(automation.persistentModelID)
                    } else {
                        ContentUnavailableView {
                            Label("No Automation", systemImage: "clock.arrow.circlepath")
                        } description: {
                            Text("Schedule a command or prompt, e.g. a summary every weekday morning.")
                        } actions: {
                            // Stacked, so narrow windows don't push the templates out of view.
                            VStack(spacing: 8) {
                                Button("New Automation", action: newAutomation)
                                Button("Add Morning Brief (/brief, weekdays 07:30)") {
                                    newAutomation(name: "Morning brief", command: "/brief")
                                }
                                Button("Add Mail Cleanup (/cleanup, hourly)") {
                                    newAutomation(name: "Mail cleanup", command: "/cleanup", trigger: .interval(minutes: 60), notify: false)
                                }
                                Button("Add Morning News (/news, weekdays 07:45)") {
                                    newAutomation(
                                        name: "Morning news", command: "/news",
                                        trigger: .daily(hour: 7, minute: 45, weekdays: AutomationTrigger.weekdaysOnly)
                                    )
                                }
                                Button("Add Newsletter Digest (/digest, weekdays 08:00)") {
                                    newAutomation(
                                        name: "Newsletter digest", command: "/digest",
                                        trigger: .daily(hour: 8, minute: 0, weekdays: AutomationTrigger.weekdaysOnly)
                                    )
                                }
                            }
                            .buttonStyle(.borderless)
                            .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas)
                    }
                } else if let selection {
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
        // Lets the quick panel and menu bar reopen this window after it was closed.
        .onAppear { app.openWindowAction = openWindow }
        .onChange(of: app.requestedConversation, initial: true) { _, id in
            guard let id, let conversation = context.model(for: id) as? Conversation else { return }
            selection = conversation
            app.requestedConversation = nil
        }
    }

    private func newAutomation() {
        newAutomation(name: "New Automation", command: "")
    }

    private func newAutomation(
        name: String,
        command: String,
        trigger: AutomationTrigger = .daily(hour: 7, minute: 30, weekdays: AutomationTrigger.weekdaysOnly),
        notify: Bool = true
    ) {
        let fresh = Automation(name: name, command: command, trigger: trigger)
        fresh.notify = notify
        context.insert(fresh)
        try? context.save()
        app.sidebarMode = .automations
        automation = fresh
    }

    private func deleteAutomation() {
        guard let automation else { return }
        context.delete(automation)
        try? context.save()
        self.automation = nil
    }

    private func openConversation(_ id: UUID) {
        guard let conversation = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first else {
            return
        }
        app.sidebarMode = .chats
        selection = conversation
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
    var conversationID: PersistentIdentifier?
    /// Set when the title can be renamed (double-click, or "Rename…" in the sidebar).
    var onRename: ((String) -> Void)?
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsSidebarControls {
                Spacer().frame(width: 64)  // traffic lights
                HeaderButton("Show Sidebar", systemImage: "sidebar.left", action: onToggleSidebar)
                HeaderButton("New Chat", systemImage: "square.and.pencil", action: onNew)
            }
            if editing {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.field)
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onKeyPress(.escape) {
                        editing = false
                        return .handled
                    }
                    .onChange(of: fieldFocused) { _, focused in if !focused && editing { commit() } }
                    .frame(maxWidth: 420)
            } else {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) { startEditing() }
                    .help(onRename == nil ? "" : "Double-click to rename")
                if onRename != nil {
                    HeaderButton("Rename", systemImage: "pencil", action: startEditing)
                        .opacity(0.7)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .headerBar()
        .onChange(of: app.renameRequest, initial: true) { _, request in
            guard let request, request == conversationID else { return }
            app.renameRequest = nil
            startEditing()
        }
    }

    private func startEditing() {
        guard onRename != nil else { return }
        draft = title
        editing = true
        fieldFocused = true
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !trimmed.isEmpty, trimmed != title { onRename?(trimmed) }
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
