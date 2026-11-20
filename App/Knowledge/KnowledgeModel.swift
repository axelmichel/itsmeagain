import AppKit
import CompanionCore
import Foundation
import Knowledge
import Observation
import Providers
import Tools

/// A folder the user added for document search. Access survives restarts via a security-scoped bookmark.
struct KnowledgeSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var bookmark: Data
    var lastIndexed: Date?
    var fileCount = 0
    var chunkCount = 0
    var lastError: String?
}

/// Folders, their index, and the embedding model (local, via Ollama).
@MainActor
@Observable
final class KnowledgeModel {
    enum Status: Equatable {
        case idle
        case indexing(IndexProgress)
    }

    private enum Keys {
        static let sources = "knowledgeSources"
        static let embeddingModel = "embeddingModel"
    }

    static let recommendedModels = [("embeddinggemma", "≈ 620 MB, multilingual"), ("nomic-embed-text", "≈ 270 MB, English")]

    private let defaults: UserDefaults
    /// The configured Ollama server (set by `AppModel`, which owns provider settings).
    @ObservationIgnored var ollama: () -> OllamaProvider = { OllamaProvider() }
    let store: KnowledgeStore

    private(set) var sources: [KnowledgeSource] {
        didSet { defaults.set(try? JSONEncoder().encode(sources), forKey: Keys.sources) }
    }

    var embeddingModel: String {
        didSet { defaults.set(embeddingModel, forKey: Keys.embeddingModel) }
    }

    private(set) var status: [KnowledgeSource.ID: Status] = [:]
    private(set) var download: OllamaProvider.PullProgress?
    private(set) var downloadError: String?
    private var accessedURLs: [KnowledgeSource.ID: URL] = [:]
    private var indexTasks: [KnowledgeSource.ID: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sources = defaults.data(forKey: Keys.sources).flatMap { try? JSONDecoder().decode([KnowledgeSource].self, from: $0) } ?? []
        embeddingModel = defaults.string(forKey: Keys.embeddingModel) ?? "embeddinggemma"
        store = KnowledgeStore(directory: AppData.knowledge)
        for source in sources { resolve(source) }
    }

    var embedder: any Embedder {
        let base = ollama()
        return OllamaProvider(id: base.id, displayName: base.displayName, baseURL: base.baseURL, embeddingModel: embeddingModel)
    }

    /// Ollama lists models as "name:tag"; "embeddinggemma" means "embeddinggemma:latest".
    func isInstalled(_ model: String, in installed: [ModelInfo]) -> Bool {
        installed.contains { $0.id == model || $0.id == model + ":latest" }
    }

    // MARK: Folders

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders whose documents ItsMeAgain may search. Files are read and indexed on this Mac."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !sources.contains(where: { $0.path == url.path(percentEncoded: false) }) {
            do {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
                let source = KnowledgeSource(name: url.lastPathComponent, path: url.path(percentEncoded: false), bookmark: bookmark)
                sources.append(source)
                resolve(source)
                reindex(source.id)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func remove(_ id: KnowledgeSource.ID) {
        indexTasks[id]?.cancel()
        accessedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        sources.removeAll { $0.id == id }
        status[id] = nil
        Task {
            await store.removeSource(id)
            try? await store.save()
        }
    }

    func reindexAll() {
        for source in sources { reindex(source.id) }
    }

    func reindex(_ id: KnowledgeSource.ID) {
        guard indexTasks[id] == nil, let url = accessedURLs[id] else {
            if accessedURLs[id] == nil { update(id) { $0.lastError = "Folder not accessible; remove and add it again." } }
            return
        }
        let indexer = DocumentIndexer(store: store, embedder: embedder, embeddingModel: embeddingModel)
        status[id] = .indexing(IndexProgress(processed: 0, total: 0, currentFile: nil))
        indexTasks[id] = Task {
            do {
                let summary = try await indexer.index(source: id, root: url) { progress in
                    Task { @MainActor in
                        if case .indexing = self.status[id] { self.status[id] = .indexing(progress) }
                    }
                }
                let stats = await store.stats(for: id)
                update(id) {
                    $0.lastIndexed = .now
                    $0.fileCount = stats.files
                    $0.chunkCount = stats.chunks
                    $0.lastError = summary.failures.isEmpty
                        ? nil
                        : "\(summary.failures.count) file(s) skipped, e.g. \(summary.failures[0])"
                }
            } catch is CancellationError {
            } catch {
                update(id) { $0.lastError = error.localizedDescription }
            }
            status[id] = .idle
            indexTasks[id] = nil
        }
    }

    private func resolve(_ source: KnowledgeSource) {
        var stale = false
        // Outside the App Sandbox `startAccessingSecurityScopedResource()` may return false but access works anyway.
        guard let url = try? URL(resolvingBookmarkData: source.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) else {
            update(source.id) { $0.lastError = "Folder not accessible; remove and add it again." }
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        accessedURLs[source.id] = url
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) {
            update(source.id) { $0.bookmark = fresh }
        }
    }

    private func update(_ id: KnowledgeSource.ID, _ change: (inout KnowledgeSource) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        change(&sources[index])
    }

    // MARK: Tool

    func makeTool() -> (any Tool)? {
        let indexed = sources.filter { $0.chunkCount > 0 }
        guard !indexed.isEmpty else { return nil }
        return SearchDocumentsTool(store: store, embedder: embedder, embeddingModel: embeddingModel, collections: indexed.map(\.name))
    }

    // MARK: Embedding model download

    func downloadEmbeddingModel(then refresh: @escaping @MainActor () async -> Void) {
        guard download == nil else { return }
        downloadError = nil
        download = OllamaProvider.PullProgress(status: "Starting…")
        let model = embeddingModel
        Task {
            do {
                for try await progress in ollama().pull(model) { download = progress }
                await refresh()
            } catch {
                downloadError = error.localizedDescription
            }
            download = nil
        }
    }
}
