import Commands
import Foundation
import Obsidian
import Persistence
import SwiftData

/// /yt-playlist → pick videos → notes with your yt tool → sorting plan → you confirm.
extension AppModel {
    /// The enabled vault that has the yt-playlist skill (its scripts are what runs).
    var clippingVault: NoteStore? {
        vaults.stores.first { FileManager.default.fileExists(atPath: $0.vault.root.appending(path: ".claude/skills/yt-playlist/playlist.py").path) }
            ?? vaults.main
    }

    func runClippingCommand(_ handler: String, input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        guard let store = clippingVault else { return .failed("No Obsidian vault is enabled (Settings → Assistant → Obsidian).") }
        let urls = input.arguments.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.contains("youtu") }
        if handler == "yt", urls.isEmpty { return .failed("Usage: /yt <YouTube URL> [more URLs]") }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        if conversation.messages.isEmpty { conversation.title = text }
        conversation.append(role: .user, content: text, task: .chat)
        let reply = conversation.append(role: .assistant, content: "", task: .chat)
        try? context.save()

        switch handler {
        case "yt-playlist":
            reply.content = "_Reading your playlist…_"
            chat.run(in: conversation, context: context) {
                guard let id = YouTubeImport.playlistID(store) else {
                    reply.content = ""
                    reply.errorText = "No playlist id found in _recherche-quellen.md (section “YouTube-Playlist”)."
                    return
                }
                do {
                    let videos = try await YouTubeImport.playlist(store, id: id)
                    let new = videos.filter(\.isNew).count
                    reply.content = "**\(videos.count) videos** in the playlist, **\(new) new**. Tick the ones you want as notes."
                    reply.attachments = [.ytPlaylist(videos)]
                } catch {
                    reply.content = ""
                    reply.errorText = error.localizedDescription
                }
            }
        case "yt":
            reply.content = "_Creating notes…_"
            createVideoNotes(urls: urls, store: store, reply: reply, in: conversation, context: context)
        default:  // einordnen
            reply.content = "_Reading Clippings/…_"
            chat.run(in: conversation, context: context) { [self] in
                await planSorting(paths: nil, store: store, reply: reply)
            }
        }
        return .handled
    }

    /// Runs the yt tool (max. 15 at a time), then plans sorting for the new notes in a new message.
    func createVideoNotes(urls: [String], store: NoteStore, reply: StoredMessage, in conversation: Conversation, context: ModelContext,
                          onEvent: (@MainActor (YouTubeImport.Event) -> Void)? = nil) {
        let batch = Array(urls.prefix(YouTubeImport.batchLimit))
        let skipped = urls.count - batch.count
        chat.run(in: conversation, context: context) { [self] in
            var saved: [String] = []
            var failed: [String] = []
            reply.content = "_Creating \(batch.count) \(batch.count == 1 ? "note" : "notes") — a minute or more per video…_"
            for await event in YouTubeImport.createNotes(urls: batch) {
                onEvent?(event)
                switch event {
                case .progress(let text): reply.content = "_\(text)_"
                case .saved(_, let path): saved.append(path)
                case .failed(let url, let reason): failed.append("\(url): \(reason)")
                case .finished: break
                }
            }
            var lines = ["**\(saved.count) \(saved.count == 1 ? "note" : "notes") created** in Clippings/."]
            if !failed.isEmpty { lines.append("Failed: " + failed.joined(separator: "; ") + " (no transcript, or YouTube is blocking — try those later).") }
            if skipped > 0 { lines.append("\(skipped) more not started: YouTube blocks transcripts after about 15 in a row — run them in a while.") }
            reply.content = lines.joined(separator: "\n")
            try? context.save()
            // Next step: the sorting plan for the new notes.
            guard !saved.isEmpty else { return }
            let plan = conversation.append(role: .assistant, content: "_Preparing the sorting…_", task: .chat)
            try? context.save()
            await planSorting(paths: saved, store: store, reply: plan)
        }
    }

    func planSorting(paths: [String]?, store: NoteStore, reply: StoredMessage) async {
        guard let model = try? localMailModel() else {
            reply.content = ""
            reply.errorText = "Sorting needs a local Chat model (Settings → Tasks → Chat)."
            return
        }
        let conventions = VaultConventions.read(store)
        let index = vaultIndex
        let (embedder, embeddingModel) = (knowledge.embedder, knowledge.embeddingModel)
        let vault = store.vault
        let proposals = await ClippingSorter.plan(
            store: store, paths: paths, conventions: conventions,
            semantic: { query in await index.search(query, vaults: [vault], embedder: embedder, model: embeddingModel) },
            provider: model.provider, model: model.model
        )
        guard !proposals.isEmpty else {
            reply.content = "Nothing to sort — Clippings/ is empty."
            return
        }
        let unsure = proposals.filter { $0.folder == nil }.count
        let duplicates = proposals.filter { !$0.duplicates.isEmpty }.count
        reply.content = "**Sorting plan for \(proposals.count) \(proposals.count == 1 ? "note" : "notes")** — check, edit, then apply. Nothing moves before that."
            + (unsure > 0 ? " \(unsure) without a clear folder." : "") + (duplicates > 0 ? " \(duplicates) look like duplicates." : "")
        reply.attachments = [.sortPlan(proposals)]
    }
}
