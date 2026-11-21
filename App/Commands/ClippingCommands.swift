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
        if handler == "yt-next" { return runYTNext(input: input, text: text, store: store, in: conversation, context: context) }
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
                          planSorting shouldPlan: Bool = true,
                          onEvent: (@MainActor (YouTubeImport.Event) -> Void)? = nil) {
        let batch = Array(urls.prefix(YouTubeImport.batchLimit))
        let skipped = urls.count - batch.count
        chat.run(in: conversation, context: context) { [self] in
            var saved: [String] = []
            var failed: [String] = []
            reply.content = "_Creating \(batch.count) \(batch.count == 1 ? "note" : "notes") — one at a time with a short pause, a minute or more each…_"
            for await event in YouTubeImport.createNotes(urls: batch) {
                onEvent?(event)
                switch event {
                case .progress(let text): reply.content = "_\(text)_"
                case .saved(_, let path): saved.append(path)
                case .failed(let url, let reason): failed.append("\(url)|\(reason)")
                case .finished: break
                }
            }
            var lines = ["**\(saved.count) \(saved.count == 1 ? "note" : "notes") created** in Clippings/."]
            // Group the reasons: one line per reason with the number of videos.
            let reasons = Dictionary(grouping: failed, by: { $0.split(separator: "|", maxSplits: 1).last.map(String.init) ?? $0 })
            for (reason, items) in reasons.sorted(by: { $0.value.count > $1.value.count }) {
                lines.append("**\(items.count) not created:** \(reason)")
            }
            if skipped > 0 { lines.append("\(skipped) more not started: at most \(YouTubeImport.batchLimit) per run (YouTube blocks after about 15 in a row) — run them later.") }
            if !failed.isEmpty { lines.append("_Failed videos stay ticked-able in the playlist card — use Retry Failed later._") }
            reply.content = lines.joined(separator: "\n")
            try? context.save()
            // Next step: the sorting plan for the new notes.
            guard !saved.isEmpty, shouldPlan else { return }
            let plan = conversation.append(role: .assistant, content: "_Preparing the sorting…_", task: .chat)
            try? context.save()
            await planSorting(paths: saved, store: store, reply: plan)
        }
    }

    // MARK: One video at a time (for the hourly automation)

    /// Videos that can never work (no transcript, unavailable): not tried again. videoID → reason.
    var ytSkipped: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "ytSkipped") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "ytSkipped") }
    }

    /// When YouTube last blocked; runs wait 3 hours after that instead of prolonging the block.
    var ytBlockedAt: Date? {
        get { UserDefaults.standard.object(forKey: "ytBlockedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "ytBlockedAt") }
    }

    static let ytBlockPause: TimeInterval = 3 * 3_600

    /// `/yt-next [n]`: the oldest new playlist video(s) (default one) as notes — no sorting plan per video.
    private func runYTNext(input: CommandInput, text: String, store: NoteStore, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        let count = input.positional.first.flatMap(Int.init).map { min(max($0, 1), YouTubeImport.batchLimit) } ?? 1
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        if conversation.messages.isEmpty { conversation.title = text }
        conversation.append(role: .user, content: text, task: .chat)
        let reply = conversation.append(role: .assistant, content: "", task: .chat)
        try? context.save()

        if let blocked = ytBlockedAt, Date.now.timeIntervalSince(blocked) < Self.ytBlockPause {
            let resume = blocked.addingTimeInterval(Self.ytBlockPause)
            reply.content = "YouTube blocked transcripts at \(blocked.formatted(date: .omitted, time: .shortened)); waiting until \(resume.formatted(date: .omitted, time: .shortened)) before trying again."
            try? context.save()
            return .handled
        }
        reply.content = "_Reading your playlist…_"
        chat.run(in: conversation, context: context) { [self] in
            guard let id = YouTubeImport.playlistID(store) else {
                reply.content = ""
                reply.errorText = "No playlist id found in _recherche-quellen.md (section “YouTube-Playlist”)."
                return
            }
            let videos: [PlaylistVideo]
            do { videos = try await YouTubeImport.playlist(store, id: id) } catch {
                reply.content = ""
                reply.errorText = error.localizedDescription
                return
            }
            let skipped = ytSkipped
            let waiting = videos.filter { $0.isNew && skipped[$0.videoID] == nil }.sorted { $0.position < $1.position }
            guard !waiting.isEmpty else {
                reply.content = "No new videos in the playlist" + (skipped.isEmpty ? "." : " (\(skipped.count) skipped for good: no transcript or unavailable).")
                return
            }
            let next = Array(waiting.prefix(count))
            var saved: [String] = []
            var failures: [String] = []
            for await event in YouTubeImport.createNotes(urls: next.map(\.url)) {
                switch event {
                case .progress(let text): reply.content = "_\(text)_"
                case .saved(_, let path): saved.append(path)
                case .failed(let url, let reason):
                    let videoID = next.first { $0.url == url }?.videoID
                    if reason == FailureReason.blocked {
                        ytBlockedAt = .now
                    } else if reason != FailureReason.notStartedBlocked, let videoID,
                        reason.hasPrefix("This video has no transcript") || reason.hasPrefix("No transcript") || reason.hasPrefix("Video unavailable") || reason.hasPrefix("Age-restricted")
                    {
                        var list = ytSkipped
                        list[videoID] = reason
                        ytSkipped = list
                    }
                    failures.append(reason)
                case .finished: break
                }
            }
            var lines: [String] = []
            if !saved.isEmpty { lines.append("Created \(saved.joined(separator: ", ")).") }
            for reason in Set(failures) { lines.append(reason) }
            let left = waiting.count - saved.count
            lines.append("\(max(left, 0)) new \(left == 1 ? "video" : "videos") left in the playlist. Sorting: /einordnen.")
            reply.content = lines.joined(separator: "\n")
        }
        return .handled
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
