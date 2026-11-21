import AppKit
import Obsidian
import Persistence
import SwiftData
import SwiftUI

/// The playlist: tick videos, then "Create notes" runs your yt tool and, when done, the sorting plan.
struct PlaylistView: View {
    let message: StoredMessage
    let index: Int
    let videos: [PlaylistVideo]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var selection: Set<String> = []
    @State private var showSeen = false
    @State private var error: String?

    private var newVideos: [PlaylistVideo] { videos.filter { $0.isNew && $0.createdNote == nil } }
    private var seen: [PlaylistVideo] { videos.filter { !$0.isNew || $0.createdNote != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !newVideos.isEmpty {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { !newVideos.isEmpty && newVideos.allSatisfy { selection.contains($0.id) } },
                        set: { on in if on { selection.formUnion(newVideos.map(\.id)) } else { selection.removeAll() } }
                    )) { Text("New (\(newVideos.count))").font(.callout.weight(.semibold)) }
                    .toggleStyle(.checkbox)
                    Spacer()
                    let failedOnes = newVideos.filter { $0.failure != nil }
                    if !failedOnes.isEmpty {
                        Button("Retry Failed (\(failedOnes.count))") { selection = Set(failedOnes.map(\.id)) }
                            .buttonStyle(.borderless)
                            .help("Selects the videos that failed; then Create Notes")
                    }
                    let count = selection.count
                    Button(count == 0 ? "Create Notes" : "Create \(count) \(count == 1 ? "Note" : "Notes")", action: create)
                        .buttonStyle(.borderedProminent)
                        .disabled(count == 0)
                        .help(count > YouTubeImport.batchLimit ? "Only the first \(YouTubeImport.batchLimit) run now (YouTube blocks more in a row)" : "Runs your yt tool, then prepares the sorting")
                }
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(newVideos) { video in row(video, selectable: true) }
                }
            } else {
                Text("No new videos in the playlist.").font(.callout).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if !seen.isEmpty {
                DisclosureGroup("Already in the vault (\(seen.count))", isExpanded: $showSeen) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(seen) { video in row(video, selectable: false) }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private func row(_ video: PlaylistVideo, selectable: Bool) -> some View {
        HStack(spacing: 8) {
            if selectable {
                Toggle("", isOn: Binding(
                    get: { selection.contains(video.id) },
                    set: { on in if on { selection.insert(video.id) } else { selection.remove(video.id) } }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }
            if let url = URL(string: video.url) {
                Link(video.title, destination: url).lineLimit(1)
            } else {
                Text(video.title).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let note = video.createdNote ?? video.existingNote {
                Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let failure = video.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selection.contains(video.id) ? Theme.selection : Theme.field)
    }

    private func create() {
        guard let store = app.clippingVault, let conversation = message.conversation else { return }
        let chosen = newVideos.filter { selection.contains($0.id) }.sorted { $0.position < $1.position }
        guard !chosen.isEmpty else { return }
        guard !app.chat.isStreaming(conversation) else {
            error = "Wait for the current reply to finish."
            return
        }
        selection.removeAll()
        for video in chosen { update(video.url) { $0.failure = nil } }
        let reply = conversation.append(role: .assistant, content: "", task: .chat)
        try? context.save()
        let urls = chosen.map(\.url)
        app.createVideoNotes(urls: urls, store: store, reply: reply, in: conversation, context: context) { event in
            // Mark the rows as the tool reports them.
            switch event {
            case .saved(let url?, let path): update(url) { $0.createdNote = path }
            case .failed(let url, let reason): update(url) { $0.failure = reason }
            default: break
            }
        }
    }

    private func update(_ url: String, _ change: (inout PlaylistVideo) -> Void) {
        var attachments = message.attachments
        guard attachments.indices.contains(index), case .ytPlaylist(var stored) = attachments[index],
            let position = stored.firstIndex(where: { $0.url == url })
        else { return }
        change(&stored[position])
        attachments[index] = .ytPlaylist(stored)
        message.attachments = attachments
        try? context.save()
    }
}

/// The sorting plan: per note folder, tags, blurb and related links — all editable — then Apply.
struct SortPlanView: View {
    let message: StoredMessage
    let index: Int
    let proposals: [SortProposal]
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var selection: Set<String> = []
    @State private var applying = false
    @State private var conventions = VaultConventions()

    private var pending: [SortProposal] { proposals.filter { $0.status == .pending || $0.status == .failed } }
    private var ready: [SortProposal] { pending.filter { $0.folder != nil && $0.duplicates.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pending.isEmpty {
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { !ready.isEmpty && ready.allSatisfy { selection.contains($0.id) } },
                        set: { on in if on { selection.formUnion(ready.map(\.id)) } else { selection.removeAll() } }
                    )) { Text("Ready to file (\(ready.count))").font(.callout.weight(.semibold)) }
                    .toggleStyle(.checkbox)
                    .disabled(ready.isEmpty)
                    Spacer()
                    if applying { ProgressView().controlSize(.small) }
                    Button("Apply \(selection.count)", action: applySelected)
                        .buttonStyle(.borderedProminent)
                        .disabled(selection.isEmpty || applying)
                        .help("Writes tags, blurb and Related block, moves the notes and adds the backlinks")
                }
            }
            ForEach(proposals) { proposal in
                ProposalRow(
                    proposal: proposal,
                    folders: conventions.topicFolders,
                    allowedTags: conventions.tags,
                    isSelected: Binding(
                        get: { selection.contains(proposal.id) },
                        set: { on in if on { selection.insert(proposal.id) } else { selection.remove(proposal.id) } }
                    ),
                    onChange: { change in update(proposal.id, change) },
                    onSkip: { update(proposal.id) { $0.status = .skipped } }
                )
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task { if let store = app.clippingVault { conventions = VaultConventions.read(store) } }
    }

    private func applySelected() {
        guard let store = app.clippingVault else { return }
        applying = true
        let chosen = pending.filter { selection.contains($0.id) }
        selection.removeAll()
        for proposal in chosen {
            do {
                let moved = try ClippingSorter.apply(proposal, store: store)
                update(proposal.id) {
                    $0.status = .applied
                    $0.appliedPath = moved
                    $0.error = nil
                }
            } catch {
                update(proposal.id) {
                    $0.status = .failed
                    $0.error = error.localizedDescription
                }
            }
        }
        applying = false
        let created = Set(chosen.filter { $0.newFolder == true }.compactMap(\.folder))
        if !created.isEmpty {
            message.content += "\n\nNew \(created.count == 1 ? "folder" : "folders"): \(created.sorted().joined(separator: ", ")). "
                + "Home.md and the folder list in CLAUDE.md weren't changed — add \(created.count == 1 ? "it" : "them") there if you want it in your overview."
            try? context.save()
        }
    }

    private func update(_ id: String, _ change: (inout SortProposal) -> Void) {
        var attachments = message.attachments
        guard attachments.indices.contains(index), case .sortPlan(var stored) = attachments[index],
            let position = stored.firstIndex(where: { $0.id == id })
        else { return }
        change(&stored[position])
        attachments[index] = .sortPlan(stored)
        message.attachments = attachments
        try? context.save()
    }
}

private struct ProposalRow: View {
    let proposal: SortProposal
    let folders: [String]
    let allowedTags: [String]
    @Binding var isSelected: Bool
    let onChange: ((inout SortProposal) -> Void) -> Void
    let onSkip: () -> Void
    @State private var blurb = ""
    @State private var naming = false
    @State private var newName = ""

    private static let newFolderTag = "__new__"

    private var editable: Bool { proposal.status == .pending || proposal.status == .failed }

    /// The folder is only created on Apply (in second-brain/), so a discarded idea leaves nothing behind.
    private func createName() {
        guard let name = NoteStore.topicFolderName(newName) else { return }
        let path = "second-brain/" + name
        let exists = folders.contains(path)
        onChange {
            $0.folder = path
            $0.newFolder = exists ? nil : true
        }
        naming = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if editable {
                    Toggle("", isOn: $isSelected)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(proposal.folder == nil || !proposal.duplicates.isEmpty)
                }
                Text(proposal.title).font(.body.weight(.medium)).lineLimit(2)
                Spacer()
                switch proposal.status {
                case .applied: Label("Filed in \(proposal.appliedPath ?? "")", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                case .skipped: Text("Left in Clippings/").font(.caption).foregroundStyle(.secondary)
                default: Button("Skip", action: onSkip).buttonStyle(.borderless).font(.caption)
                }
            }
            if editable {
                if !proposal.duplicates.isEmpty {
                    Label("Duplicate of \(proposal.duplicates.joined(separator: ", ")) — stays in Clippings/", systemImage: "doc.on.doc")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Picker("Folder", selection: Binding(
                        get: { naming ? Self.newFolderTag : (proposal.folder ?? "") },
                        set: { value in
                            if value == Self.newFolderTag {
                                naming = true
                                newName = ""
                            } else {
                                naming = false
                                onChange {
                                    $0.folder = value.isEmpty ? nil : value
                                    $0.newFolder = nil
                                }
                            }
                        }
                    )) {
                        Text("Unsure — choose a folder").tag("")
                        ForEach(folders, id: \.self) { Text($0.replacingOccurrences(of: "second-brain/", with: "")).tag($0) }
                        if proposal.newFolder == true, let folder = proposal.folder, !folders.contains(folder) {
                            Text(folder.replacingOccurrences(of: "second-brain/", with: "") + " (new)").tag(folder)
                        }
                        Divider()
                        Text("New folder…").tag(Self.newFolderTag)
                    }
                    .frame(maxWidth: 360)
                    if naming {
                        TextField("Folder name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .onSubmit(createName)
                        Button("OK", action: createName).disabled(NoteStore.topicFolderName(newName) == nil)
                    } else if proposal.newFolder == true {
                        Text("created when you apply").font(.caption).foregroundStyle(Theme.accent)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Blurb\(proposal.blurbIsNew ? " (new)" : "")").font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                    TextField("One sentence, English", text: $blurb, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .onSubmit { onChange { $0.blurb = blurb } }
                        .onChange(of: blurb) { _, value in onChange { $0.blurb = value } }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Tags").font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                    Text(proposal.tags.joined(separator: " · ")).font(.callout)
                    Menu("Edit") {
                        ForEach(allowedTags, id: \.self) { tag in
                            Button((proposal.tags.contains(tag) ? "✓ " : "") + tag) {
                                onChange { proposal in
                                    if let position = proposal.tags.firstIndex(of: tag) { proposal.tags.remove(at: position) } else { proposal.tags.append(tag) }
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                if !proposal.related.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Related").font(.caption).foregroundStyle(.secondary)
                        ForEach(proposal.related, id: \.note) { link in
                            HStack(alignment: .firstTextBaseline) {
                                Text("[[\(link.note)]]").font(.callout.monospaced())
                                Text(link.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Spacer()
                                Button("Remove", systemImage: "minus.circle") { onChange { $0.related.removeAll { $0.note == link.note } } }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let error = proposal.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(10)
        .background(isSelected ? Theme.selection : Theme.field)
        .onAppear { blurb = proposal.blurb }
    }
}
