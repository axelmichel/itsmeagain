import CompanionCore
import CryptoKit
import Foundation
import Knowledge
import Observation
import Obsidian

/// Meaning-based search over the enabled vaults: one embedding index (local model), kept up to date
/// in the background — only changed notes are re-read.
@MainActor
@Observable
final class VaultIndex {
    static let interval: TimeInterval = 30 * 60

    struct Status: Equatable {
        var files = 0
        var lastIndexed: Date?
        var progress: String?
        var error: String?
    }

    private(set) var status: [String: Status] = [:]
    private(set) var isIndexing = false

    @ObservationIgnored nonisolated let store = KnowledgeStore(directory: AppData.directory.appending(path: "VaultIndex", directoryHint: .isDirectory))
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var vaults: () -> [Vault] = { [] }
    @ObservationIgnored var embedder: () -> (embedder: any Embedder, model: String) = { (OllamaFallbackEmbedder(), "") }

    /// A stable id per vault path, so the index survives restarts.
    nonisolated static func sourceID(_ vault: Vault) -> UUID {
        let digest = Array(SHA256.hash(data: Data(vault.path.utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    func start() {
        Task {
            try? await Task.sleep(for: .seconds(45))
            await indexAll()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.indexAll() }
            }
        }
    }

    func indexAll() async {
        guard !isIndexing else { return }
        isIndexing = true
        defer { isIndexing = false }
        let (embedder, model) = embedder()
        let indexer = DocumentIndexer(store: store, embedder: embedder, embeddingModel: model)
        for vault in vaults() {
            var current = status[vault.path] ?? Status()
            current.progress = "Indexing…"
            status[vault.path] = current
            do {
                let summary = try await indexer.index(source: Self.sourceID(vault), root: vault.root) { progress in
                    let text = progress.total > 0 ? "Indexing \(progress.processed) of \(progress.total)…" : nil
                    Task { @MainActor in self.status[vault.path]?.progress = text }
                }
                current.files = await store.stats(for: Self.sourceID(vault)).files
                current.lastIndexed = .now
                current.error = summary.failures.isEmpty ? nil : "\(summary.failures.count) notes skipped"
            } catch {
                current.error = error.localizedDescription.contains("Could not connect")
                    ? "Ollama isn't running" : error.localizedDescription
            }
            current.progress = nil
            status[vault.path] = current
        }
    }

    func rebuild() {
        Task {
            for vault in vaults() { await store.removeSource(Self.sourceID(vault)) }
            try? await store.save()
            await indexAll()
        }
    }

    /// Notes by meaning, mapped back to vault-relative paths. Empty when nothing is indexed yet.
    nonisolated func search(_ query: String, vaults: [Vault], embedder: any Embedder, model: String) async -> [SemanticNoteHit] {
        guard await store.embeddingModel == model, await store.chunkCount > 0,
            let vector = try? await embedder.embed([EmbeddingStyle.forModel(model).query(query)]).first
        else { return [] }
        let sources = Dictionary(uniqueKeysWithValues: vaults.map { (Self.sourceID($0), $0) })
        let hits = await store.search(vector, limit: 12, sources: Set(sources.keys))
        return hits.compactMap { hit in
            guard let vault = sources[hit.chunk.sourceID] else { return nil }
            let root = vault.root.standardizedFileURL.path
            let path = hit.chunk.path.hasPrefix(root + "/") ? String(hit.chunk.path.dropFirst(root.count + 1)) : hit.chunk.path
            let snippet = hit.chunk.text.replacingOccurrences(of: "\n", with: " ").prefix(200)
            return SemanticNoteHit(vault: vault.name, path: path, snippet: String(snippet), score: hit.score)
        }
    }
}

/// Placeholder until the app wires the real embedder.
struct OllamaFallbackEmbedder: Embedder {
    func embed(_ texts: [String]) async throws -> [[Float]] { throw ProviderError.unavailable("No embedding model") }
}
