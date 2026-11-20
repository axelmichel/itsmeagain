import CompanionCore
import Foundation

/// Model-specific prompt prefixes; several embedding models are trained with them and retrieve worse without.
public struct EmbeddingStyle: Sendable {
    public var document: @Sendable (_ title: String, _ text: String) -> String
    public var query: @Sendable (String) -> String

    public static func forModel(_ model: String) -> EmbeddingStyle {
        let name = model.lowercased()
        if name.contains("embeddinggemma") {
            return EmbeddingStyle(document: { "title: \($0) | text: \($1)" }, query: { "task: search result | query: \($0)" })
        }
        if name.contains("nomic-embed") {
            return EmbeddingStyle(document: { "search_document: \($0)\n\($1)" }, query: { "search_query: \($0)" })
        }
        if name.contains("mxbai-embed") {
            return EmbeddingStyle(
                document: { "\($0)\n\($1)" },
                query: { "Represent this sentence for searching relevant passages: \($0)" }
            )
        }
        return EmbeddingStyle(document: { "\($0)\n\($1)" }, query: { $0 })
    }
}

public struct IndexProgress: Sendable, Equatable {
    public var processed: Int
    public var total: Int
    public var currentFile: String?

    public init(processed: Int, total: Int, currentFile: String?) {
        self.processed = processed
        self.total = total
        self.currentFile = currentFile
    }
}

public struct IndexSummary: Sendable, Equatable {
    public var indexed: Int
    public var removed: Int
    public var unchanged: Int
    public var failures: [String]
}

/// Incrementally indexes a folder: only new or modified files are embedded, deleted files are dropped.
public struct DocumentIndexer: Sendable {
    public let store: KnowledgeStore
    public let embedder: any Embedder
    public let embeddingModel: String
    public var maxFileBytes = 10_000_000
    public var batchSize = 16

    static let skippedDirectories: Set<String> = [
        "node_modules", ".git", ".build", "build", "DerivedData", "Pods", "dist", "venv", ".venv", "__pycache__", "target",
    ]

    public init(store: KnowledgeStore, embedder: any Embedder, embeddingModel: String) {
        self.store = store
        self.embedder = embedder
        self.embeddingModel = embeddingModel
    }

    public func index(
        source: UUID,
        root: URL,
        progress: @Sendable (IndexProgress) -> Void = { _ in }
    ) async throws -> IndexSummary {
        await store.prepare(for: embeddingModel)
        let style = EmbeddingStyle.forModel(embeddingModel)

        let current = scan(root, source: source)
        let known = Dictionary(uniqueKeysWithValues: await store.files(in: source).map { ($0.path, $0) })
        let changed = current.filter { file in
            guard let old = known[file.path] else { return true }
            return old.modified != file.modified || old.size != file.size
        }
        let deleted = Set(known.keys).subtracting(current.map(\.path))
        await store.remove(paths: deleted.union(changed.map(\.path)))

        var failures: [String] = []
        for (number, file) in changed.enumerated() {
            try Task.checkCancellation()
            progress(IndexProgress(processed: number, total: changed.count, currentFile: file.path))
            do {
                let url = URL(filePath: file.path)
                let document = try DocumentReader.read(url)
                let pieces = Chunker.chunks(document.text)
                var vectors: [[Float]] = []
                for batch in stride(from: 0, to: pieces.count, by: batchSize) {
                    let slice = pieces[batch..<min(batch + batchSize, pieces.count)]
                    vectors += try await embedder.embed(slice.map { style.document(document.title, $0.text) })
                }
                let chunks = pieces.map {
                    KnowledgeChunk(id: UUID(), sourceID: source, path: file.path, title: document.title, text: $0.text, offset: $0.offset)
                }
                try await store.add(file, chunks: chunks, vectors: vectors)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(URL(filePath: file.path).lastPathComponent): \(error.localizedDescription)")
            }
            if number % 50 == 49 { try await store.save() }
        }
        try await store.save()
        progress(IndexProgress(processed: changed.count, total: changed.count, currentFile: nil))
        return IndexSummary(indexed: changed.count - failures.count, removed: deleted.count, unchanged: current.count - changed.count, failures: failures)
    }

    func scan(_ root: URL, source: UUID) -> [IndexedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [IndexedFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if Self.skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, DocumentReader.isSupported(url),
                let size = values.fileSize, size > 0, size <= maxFileBytes
            else { continue }
            files.append(IndexedFile(sourceID: source, path: url.standardizedFileURL.path(percentEncoded: false), modified: values.contentModificationDate ?? .distantPast, size: size))
        }
        return files
    }
}
