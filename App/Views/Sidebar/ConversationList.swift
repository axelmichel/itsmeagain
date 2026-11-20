import Persistence
import SwiftData
import SwiftUI

struct ConversationList: View {
    @Binding var selection: Conversation?
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var search = ""

    private var filtered: [Conversation] {
        guard !search.isEmpty else { return conversations }
        return conversations.filter { $0.title.localizedStandardContains(search) }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .lineLimit(1)
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(conversation)
                .contextMenu {
                    Button("Delete", role: .destructive) { delete(conversation) }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar)
        .onDeleteCommand {
            if let selection { delete(selection) }
        }
    }

    private func delete(_ conversation: Conversation) {
        app.chat.stop(conversation)
        if selection == conversation { selection = nil }
        context.delete(conversation)
        try? context.save()
    }
}
