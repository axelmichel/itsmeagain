import AppKit
import Memory
import SwiftUI
import UniformTypeIdentifiers

/// One memory: text (editable in place), kind, where it came from; actions depend on its status.
struct MemoryRow: View {
    let item: MemoryItem
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var draft = ""
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var memory: MemoryModel { app.memory }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(item.status == .pending ? Theme.accent : .secondary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Memory", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onKeyPress(.escape) {
                            editing = false
                            return .handled
                        }
                } else {
                    Text(item.text)
                        .strikethrough(item.status == .archived)
                        .foregroundStyle(item.status == .archived ? .secondary : .primary)
                        .textSelection(.enabled)
                        .onTapGesture(count: 2) { startEditing() }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovered ? Theme.hover : Theme.field)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Edit") { startEditing() }
            Menu("Kind") {
                ForEach(MemoryKind.allCases) { kind in
                    Button(kind.title) { memory.edit(item.id, text: item.text, kind: kind) }
                }
            }
            Divider()
            if item.status == .archived {
                Button("Restore") { memory.restore(item.id) }
            } else {
                Button("Forget") { memory.archive(item.id) }
            }
            Button("Delete Permanently", role: .destructive) { memory.delete(item.id) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if editing {
            Button("Save", action: commit)
        } else {
            switch item.status {
            case .pending:
                HStack(spacing: 10) {
                    Button(item.replaces == nil ? "Keep" : "Update") { memory.accept(item.id) }
                        .fontWeight(.semibold)
                    Button("Wrong") { memory.delete(item.id) }
                }
            case .active:
                if hovered {
                    HStack(spacing: 10) {
                        Button("Edit") { startEditing() }
                        Button("Forget") { memory.archive(item.id) }
                    }
                }
            case .archived:
                Button("Restore") { memory.restore(item.id) }
            }
        }
    }

    private var icon: String {
        switch item.kind {
        case .profile: "person.crop.circle"
        case .preference: "slider.horizontal.3"
        case .person: "person.2"
        case .routine: "repeat"
        case .project: "folder"
        case .instruction: "checklist"
        }
    }

    private var details: String {
        var parts = [item.kind.title]
        if let subject = item.subject { parts.append(subject) }
        parts.append(item.source == .learned ? "learned from your messages" : "you told me")
        if item.sensitive { parts.append("sensitive") }
        if item.status == .pending, let old = item.replaces.flatMap(memory.book.item) { parts.append("replaces “\(old.text)”") }
        parts.append(item.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private func startEditing() {
        draft = item.text
        editing = true
        focused = true
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !text.isEmpty, text != item.text { memory.edit(item.id, text: text) }
    }
}

/// Memories in the transcript (/remember, /forget, /memories); read live, so changes show everywhere.
struct MemoryListView: View {
    let title: String
    let ids: [UUID]
    @Environment(AppModel.self) private var app

    var body: some View {
        let items = ids.compactMap(app.memory.book.item)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold))
            if items.isEmpty {
                Text("Deleted.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(items) { MemoryRow(item: $0) }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }
}

/// The Memory tab: what to review, everything known by kind, and the archive.
struct MemoryPage: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var newText = ""
    @State private var newKind: MemoryKind = .preference
    @State private var showArchive = false

    private var memory: MemoryModel { app.memory }

    private func filtered(_ items: [MemoryItem]) -> [MemoryItem] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.text.localizedStandardContains(search) || ($0.subject?.localizedStandardContains(search) ?? false) }
    }

    var body: some View {
        @Bindable var memory = memory
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    TextField("Search memories", text: $search)
                        .textFieldStyle(.plain)
                        .padding(6)
                        .background(Theme.field)
                        .frame(maxWidth: 260)
                    Toggle("Learn from my Chat messages", isOn: $memory.learningEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    if memory.isLearning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Export…", action: export)
                }

                HStack(spacing: 8) {
                    TextField("Tell me something to remember…", text: $newText)
                        .textFieldStyle(.plain)
                        .padding(6)
                        .background(Theme.field)
                        .onSubmit(add)
                    Picker("Kind", selection: $newKind) {
                        ForEach(MemoryKind.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add", action: add)
                        .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                let pending = filtered(memory.book.pending)
                if !pending.isEmpty {
                    section("To review (\(pending.count))", footer: "Learned from your own Chat messages. Keep what's right, mark the rest as wrong.") {
                        ForEach(pending) { MemoryRow(item: $0) }
                    }
                }

                let active = filtered(memory.book.active)
                if active.isEmpty && pending.isEmpty {
                    Text(search.isEmpty
                        ? "Nothing remembered yet. Use /remember in Chat, add something above, or just chat — I learn from what you say (only your own messages, only on this Mac)."
                        : "No memories match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(MemoryKind.allCases) { kind in
                    let items = active.filter { $0.kind == kind }
                    if !items.isEmpty {
                        section("\(kind.title) (\(items.count))") {
                            ForEach(items) { MemoryRow(item: $0) }
                        }
                    }
                }

                let archived = filtered(memory.book.items.filter { $0.status == .archived })
                if !archived.isEmpty {
                    DisclosureGroup("Forgotten (\(archived.count))", isExpanded: $showArchive) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(archived) { MemoryRow(item: $0) }
                        }
                        .padding(.top, 6)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }

    private func section<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1, content: content)
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func add() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newText = ""
        let kind = newKind
        Task { await memory.add(text, kind: kind) }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ItsMeAgain Memory.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? MemoryExport.markdown(memory.book).write(to: url, atomically: true, encoding: .utf8)
    }
}
