import CompanionCore
import SwiftUI

/// Folders for document search, and the local embedding model that indexes them.
struct KnowledgeSettings: View {
    @Environment(AppModel.self) private var app

    private var knowledge: KnowledgeModel { app.knowledge }
    private var ollamaModels: [ModelInfo] { app.models[.ollama] ?? [] }
    private var modelInstalled: Bool { knowledge.isInstalled(knowledge.embeddingModel, in: ollamaModels) }

    var body: some View {
        @Bindable var knowledge = app.knowledge
        Form {
            Section {
                Picker("Embedding Model", selection: $knowledge.embeddingModel) {
                    ForEach(KnowledgeModel.recommendedModels, id: \.0) { name, note in
                        Text("\(name)  —  \(note)").tag(name)
                    }
                    let others = ollamaModels.map(\.id).filter { id in
                        !KnowledgeModel.recommendedModels.contains { id == $0.0 || id == $0.0 + ":latest" }
                    }
                    if !KnowledgeModel.recommendedModels.contains(where: { $0.0 == knowledge.embeddingModel }),
                        !others.contains(knowledge.embeddingModel)
                    {
                        Text(knowledge.embeddingModel).tag(knowledge.embeddingModel)
                    }
                    if !others.isEmpty {
                        Section("Other Ollama Models") {
                            ForEach(others, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                LabeledContent("Status") { modelStatus }
            } header: {
                Text("Embedding Model")
            } footer: {
                Text("Turns your documents into searchable vectors, locally via Ollama. Changing the model reindexes all folders.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if knowledge.sources.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                }
                ForEach(knowledge.sources) { source in
                    SourceRow(source: source, status: knowledge.status[source.id] ?? .idle)
                }
                HStack {
                    Button("Add Folder…", systemImage: "plus") { knowledge.addFolder() }
                        .disabled(!modelInstalled)
                    Spacer()
                    Button("Update All") { knowledge.reindexAll() }
                        .disabled(knowledge.sources.isEmpty || !modelInstalled)
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("""
                    Text, Markdown, code, HTML, PDF, RTF and Word files are indexed on this Mac. Only new or changed files \
                    are processed on update. Tasks with “Search My Documents” enabled (Research by default) can use them. \
                    If a task uses a cloud model, the passages it finds are sent to that provider.
                    """)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onChange(of: knowledge.embeddingModel) { knowledge.reindexAll() }
    }

    @ViewBuilder
    private var modelStatus: some View {
        if let download = knowledge.download {
            HStack {
                if let fraction = download.fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(download.status).foregroundStyle(.secondary)
            }
        } else if modelInstalled {
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else if app.modelErrors[.ollama] != nil {
            Text("Ollama is not reachable").foregroundStyle(.red)
        } else {
            HStack {
                if let error = knowledge.downloadError {
                    Text(error).foregroundStyle(.red)
                }
                Button("Download \(knowledge.embeddingModel)") {
                    knowledge.downloadEmbeddingModel { await app.refreshModels() }
                }
            }
        }
    }
}

private struct SourceRow: View {
    let source: KnowledgeSource
    let status: KnowledgeModel.Status
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(source.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail.font(.caption)
            }
            Spacer()
            Button("Update", systemImage: "arrow.clockwise") { app.knowledge.reindex(source.id) }
                .disabled(status != .idle)
            Button("Remove", systemImage: "minus.circle") { app.knowledge.remove(source.id) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var detail: some View {
        switch status {
        case .indexing(let progress):
            HStack {
                ProgressView(value: progress.total > 0 ? Double(progress.processed) / Double(progress.total) : 0)
                    .frame(width: 100)
                Text(progress.total > 0 ? "Indexing \(progress.processed)/\(progress.total)" : "Scanning…")
                    .foregroundStyle(.secondary)
            }
        case .idle:
            if let error = source.lastError {
                Text(error).foregroundStyle(.orange)
            } else if let date = source.lastIndexed {
                Text("\(source.fileCount) files · \(source.chunkCount) passages · updated \(date, format: .relative(presentation: .named))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Not indexed yet").foregroundStyle(.secondary)
            }
        }
    }
}
