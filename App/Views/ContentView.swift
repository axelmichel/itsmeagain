import Persistence
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var selection: Conversation?

    var body: some View {
        NavigationSplitView {
            ConversationList(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
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
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("New Chat", systemImage: "square.and.pencil", action: newConversation)
                    .keyboardShortcut("n")
            }
        }
        .task { await app.refreshModels() }
    }

    private func newConversation() {
        // Reuse an untouched conversation instead of piling up empty ones.
        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        if let empty = all.first(where: { $0.messages.isEmpty }) {
            selection = empty
            return
        }
        let conversation = Conversation(providerID: app.ollama.id.rawValue, modelID: app.defaultModel)
        context.insert(conversation)
        try? context.save()
        selection = conversation
    }
}
