import Accelerate
import Foundation

public struct KnowledgeChunk: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var path: String
    public var title: String
    public var text: String
    public var offset: Int
}

public struct IndexedFile: Codable, Sendable, Hashable {
    public var sourceID: UUID
    public var path: String
    public var modified: Date
    public var size: Int
}

public struct SearchHit: Sendable, Hashable {
    public var chunk: KnowledgeChunk
    public var score: Float
}

/// Passages and their embeddings, all in memory (personal-scale corpora), persisted to a directory as
/// `index.json` (metadata) and `vectors.bin` (normalized Float32 vectors in chunk order).
public actor KnowledgeStore {
    private struct Snapshot: Codable {
        var embeddingModel: String?
        var dimension: Int
        var chunks: [KnowledgeChunk]
        var files: [IndexedFile]
    }

    private let directory: URL?
    private var chunks: [KnowledgeChunk] = []
    private var vectors: [[Float]] = []
    private var files: [String: IndexedFile] = [:]
    public private(set) var embeddingModel: String?
    public private(set) var dimension = 0
    private var dirty = false

    /// `directory == nil` keeps everything in memory (tests).
    public init(directory: URL?) {
        self.directory = directory
        guard let directory,
            let json = try? Data(contentsOf: directory.appending(path: "index.json")),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: json),
            let raw = try? Data(contentsOf: directory.appending(path: "vectors.bin")),
            raw.count == snapshot.chunks.count * snapshot.dimension * MemoryLayout<Float>.size
        else { return }
        let flat = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        embeddingModel = snapshot.embeddingModel
        dimension = snapshot.dimension
        chunks = snapshot.chunks
        vectors = (0..<snapshot.chunks.count).map { Array(flat[($0 * snapshot.dimension)..<(($0 + 1) * snapshot.dimension)]) }
        files = Dictionary(snapshot.files.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
    }

    public var chunkCount: Int { chunks.count }

    public func files(in source: UUID) -> [IndexedFile] {
        files.values.filter { $0.sourceID == source }
    }

    public func stats(for source: UUID) -> (files: Int, chunks: Int) {
        (files.values.count { $0.sourceID == source }, chunks.count { $0.sourceID == source })
    }

    /// Vectors from different models can't be compared, so switching models empties the store.
    public func prepare(for model: String) {
        guard embeddingModel != model else { return }
        chunks = []
        vectors = []
        files = [:]
        dimension = 0
        embeddingModel = model
        dirty = true
    }

    public func remove(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        for path in paths { files[path] = nil }
        let keep = chunks.indices.filter { !paths.contains(chunks[$0].path) }
        chunks = keep.map { chunks[$0] }
        vectors = keep.map { vectors[$0] }
        dirty = true
    }

    public func removeSource(_ source: UUID) {
        remove(paths: Set(files.values.filter { $0.sourceID == source }.map(\.path)))
    }

    public func add(_ file: IndexedFile, chunks newChunks: [KnowledgeChunk], vectors newVectors: [[Float]]) throws {
        precondition(newChunks.count == newVectors.count)
        if let first = newVectors.first {
            if dimension == 0 { dimension = first.count }
            guard newVectors.allSatisfy({ $0.count == dimension }) else {
                throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "embedding dimension changed"])
            }
        }
        files[file.path] = file
        chunks += newChunks
        vectors += newVectors.map(Self.normalized)
        dirty = true
    }

    /// Cosine similarity (vectors are normalized, so a dot product).
    public func search(_ query: [Float], limit: Int, sources: Set<UUID>? = nil) -> [SearchHit] {
        guard query.count == dimension, !chunks.isEmpty else { return [] }
        let q = Self.normalized(query)
        var hits: [SearchHit] = []
        hits.reserveCapacity(chunks.count)
        for index in chunks.indices where sources?.contains(chunks[index].sourceID) ?? true {
            hits.append(SearchHit(chunk: chunks[index], score: vDSP.dot(q, vectors[index])))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    public func save() throws {
        guard dirty, let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = Snapshot(embeddingModel: embeddingModel, dimension: dimension, chunks: chunks, files: Array(files.values))
        let flat = vectors.flatMap { $0 }
        try flat.withUnsafeBytes { Data($0) }.write(to: directory.appending(path: "vectors.bin"), options: .atomic)
        try JSONEncoder().encode(snapshot).write(to: directory.appending(path: "index.json"), options: .atomic)
        dirty = false
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let length = sqrt(vDSP.sumOfSquares(vector))
        return length > 0 ? vDSP.divide(vector, length) : vector
    }
}
