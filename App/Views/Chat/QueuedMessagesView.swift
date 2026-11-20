import SwiftUI

/// Messages waiting to be sent after the running reply.
struct QueuedMessagesView: View {
    let messages: [ChatController.QueuedMessage]
    let isPaused: Bool
    let onEdit: (ChatController.QueuedMessage) -> Void
    let onRemove: (ChatController.QueuedMessage) -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(
                    isPaused ? "Queue paused" : "Queued — sent after the current reply",
                    systemImage: isPaused ? "pause.circle" : "tray.full"
                )
                Spacer()
                if isPaused {
                    Button("Resume", systemImage: "play.fill", action: onResume)
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(messages) { message in
                HStack(spacing: 8) {
                    Text(message.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit", systemImage: "pencil") { onEdit(message) }
                        .help("Move back into the editor")
                    Button("Remove", systemImage: "xmark") { onRemove(message) }
                        .help("Remove from the queue")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.selection)
            }
        }
        .padding(.horizontal, 12)
    }
}
