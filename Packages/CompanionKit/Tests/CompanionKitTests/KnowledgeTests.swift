import AppKit
import CompanionCore
import Foundation
import Synchronization
import Testing

@testable import Knowledge
@testable import Providers
@testable import Tools

/// Bag-of-words embedder with a stable hash: texts sharing words get similar vectors.
final class WordEmbedder: Embedder, @unchecked Sendable {
    let calls = Mutex<[[String]]>([])

    func embed(_ texts: [String]) async throws -> [[Float]] {
        calls.withLock { $0.append(texts) }
        return texts.map { text in
            var vector = [Float](repeating: 0, count: 64)
            for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count > 2 {
                let hash = word.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
                vector[Int(hash % 64)] += 1
            }
            return vector
        }
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "itsmeagain-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ChunkerTests {
    @Test func shortTextIsOneChunk() {
        #expect(Chunker.chunks("  Hello world.  ") == [Chunker.Chunk(offset: 0, text: "Hello world.")])
        #expect(Chunker.chunks("") == [])
    }

    @Test func splitsAtParagraphsWithOverlapAndCoversEverything() {
        let paragraphs = (1...12).map { "Paragraph \($0) " + String(repeating: "word\($0) ", count: 30) }
        let text = paragraphs.joined(separator: "\n\n")
        let chunks = Chunker.chunks(text, size: 600, overlap: 100)

        #expect(chunks.count > 3)
        #expect(chunks.allSatisfy { $0.text.count <= 600 })
        // Every paragraph's distinctive word appears somewhere.
        for n in 1...12 { #expect(chunks.contains { $0.text.contains("word\(n) ") || $0.text.hasSuffix("word\(n)") }) }
        // Chunks end on a paragraph boundary when one is available, and consecutive chunks overlap.
        #expect(chunks.dropLast().allSatisfy { $0.text.hasSuffix(" ") == false })
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(b.offset < a.offset + a.text.count + 2, "chunks should overlap or touch")
        }
    }

    @Test func neverStartsMidWord() {
        let text = String(repeating: "alpha beta gamma delta ", count: 200)
        for chunk in Chunker.chunks(text, size: 300, overlap: 50) {
            #expect(["alpha", "beta", "gamma", "delta"].contains { chunk.text.hasPrefix($0) })
        }
    }
}

@Suite struct DocumentReaderTests {
    @Test func readsPlainMarkdownHTMLAndRTF() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let md = dir.appending(path: "notes.md")
        try "# Notes\nBuy milk".write(to: md, atomically: true, encoding: .utf8)
        #expect(try DocumentReader.read(md) == ("notes", "# Notes\nBuy milk"))

        let html = dir.appending(path: "page.html")
        try "<html><head><title>Page</title></head><body><nav>menu</nav><p>Hello</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        #expect(try DocumentReader.read(html) == ("Page", "Hello"))

        let rtf = dir.appending(path: "letter.rtf")
        let data = try NSAttributedString(string: "Dear Axel").data(
            from: NSRange(location: 0, length: 9), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try data.write(to: rtf)
        #expect(try DocumentReader.read(rtf).text.contains("Dear Axel"))

        let latin1 = dir.appending(path: "old.txt")
        try Data([0x47, 0x72, 0xFC, 0xDF, 0x65]).write(to: latin1)  // "Grüße" in Latin-1
        #expect(try DocumentReader.read(latin1).text == "Grüße")

        #expect(DocumentReader.isSupported(URL(filePath: "/x/a.PDF")))
        #expect(!DocumentReader.isSupported(URL(filePath: "/x/a.png")))
    }
}

@Suite struct KnowledgeStoreTests {
    let source = UUID()

    func chunk(_ path: String, _ text: String) -> KnowledgeChunk {
        KnowledgeChunk(id: UUID(), sourceID: source, path: path, title: path, text: text, offset: 0)
    }

    func file(_ path: String) -> IndexedFile {
        IndexedFile(sourceID: source, path: path, modified: .distantPast, size: 1)
    }

    @Test func searchesRemovesAndPersists() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = KnowledgeStore(directory: dir)
        await store.prepare(for: "m")
        try await store.add(file("/a"), chunks: [chunk("/a", "apples")], vectors: [[1, 0, 0]])
        try await store.add(file("/b"), chunks: [chunk("/b", "bananas"), chunk("/b", "mixed")], vectors: [[0, 2, 0], [1, 1, 0]])

        let hits = await store.search([3, 0.1, 0], limit: 2)
        #expect(hits.map(\.chunk.text) == ["apples", "mixed"])
        #expect(abs(hits[0].score - 0.9994) < 0.001, "cosine, independent of vector length")

        try await store.save()
        let reloaded = KnowledgeStore(directory: dir)
        #expect(await reloaded.chunkCount == 3)
        #expect(await reloaded.embeddingModel == "m")
        #expect(await reloaded.search([0, 1, 0], limit: 1).first?.chunk.text == "bananas")

        await reloaded.remove(paths: ["/b"])
        #expect(await reloaded.chunkCount == 1)
        #expect(await reloaded.stats(for: source) == (files: 1, chunks: 1))
    }

    @Test func switchingEmbeddingModelClearsIndex() async throws {
        let store = KnowledgeStore(directory: nil)
        await store.prepare(for: "a")
        try await store.add(file("/a"), chunks: [chunk("/a", "x")], vectors: [[1, 0]])
        await store.prepare(for: "a")
        #expect(await store.chunkCount == 1)
        await store.prepare(for: "b")
        #expect(await store.chunkCount == 0)
        #expect(await store.dimension == 0)
    }

    @Test func rejectsMismatchedDimensions() async throws {
        let store = KnowledgeStore(directory: nil)
        try await store.add(file("/a"), chunks: [chunk("/a", "x")], vectors: [[1, 0]])
        await #expect(throws: CocoaError.self) {
            try await store.add(file("/b"), chunks: [chunk("/b", "y")], vectors: [[1, 0, 0]])
        }
    }
}

@Suite struct DocumentIndexerTests {
    @Test func indexesIncrementallyAndSearches() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "Kubernetes deployment notes: rolling updates and pods".write(to: root.appending(path: "k8s.md"), atomically: true, encoding: .utf8)
        try "Sourdough bread recipe with flour water salt".write(to: root.appending(path: "bread.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "node_modules"), withIntermediateDirectories: true)
        try "ignored dependency".write(to: root.appending(path: "node_modules/x.js"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50]).write(to: root.appending(path: "image.png"))

        let store = KnowledgeStore(directory: nil)
        let embedder = WordEmbedder()
        let indexer = DocumentIndexer(store: store, embedder: embedder, embeddingModel: "embeddinggemma")
        let source = UUID()

        let first = try await indexer.index(source: source, root: root)
        #expect(first == IndexSummary(indexed: 2, removed: 0, unchanged: 0, failures: []))
        #expect(embedder.calls.withLock { $0.flatMap { $0 } }.allSatisfy { $0.hasPrefix("title: ") }, "document prefix for embeddinggemma")

        // Nothing changed → nothing embedded.
        let callsBefore = embedder.calls.withLock { $0.count }
        #expect(try await indexer.index(source: source, root: root) == IndexSummary(indexed: 0, removed: 0, unchanged: 2, failures: []))
        #expect(embedder.calls.withLock { $0.count } == callsBefore)

        // Modify one, delete the other.
        try await Task.sleep(for: .milliseconds(1100))  // mtime resolution
        try "Kubernetes notes: helm charts and pods".write(to: root.appending(path: "k8s.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "bread.txt"))
        #expect(try await indexer.index(source: source, root: root) == IndexSummary(indexed: 1, removed: 1, unchanged: 0, failures: []))
        #expect(await store.stats(for: source) == (files: 1, chunks: 1))

        let tool = SearchDocumentsTool(store: store, embedder: embedder, embeddingModel: "embeddinggemma", collections: ["Notes"])
        let output = try await tool.run(["query": "helm charts"])
        #expect(output.content.contains("helm charts"))
        #expect(output.sources.first?.url.hasPrefix("file://") == true)
        #expect(output.sources.first?.url.hasSuffix("k8s.md") == true)
    }

    @Test func toolRefusesIndexFromAnotherModel() async throws {
        let store = KnowledgeStore(directory: nil)
        await store.prepare(for: "nomic-embed-text")
        try await store.add(
            IndexedFile(sourceID: UUID(), path: "/a", modified: .now, size: 1),
            chunks: [KnowledgeChunk(id: UUID(), sourceID: UUID(), path: "/a", title: "a", text: "a", offset: 0)],
            vectors: [[1]]
        )
        let tool = SearchDocumentsTool(store: store, embedder: WordEmbedder(), embeddingModel: "embeddinggemma", collections: [])
        await #expect(throws: ToolError.self) { try await tool.run(["query": "x"]) }
    }

    @Test func embeddingStylesUseModelPrefixes() {
        #expect(EmbeddingStyle.forModel("embeddinggemma:latest").query("q") == "task: search result | query: q")
        #expect(EmbeddingStyle.forModel("nomic-embed-text").query("q") == "search_query: q")
        #expect(EmbeddingStyle.forModel("other").query("q") == "q")
    }
}

@Suite struct OllamaPullTests {
    @Test func reportsProgressAndErrors() async throws {
        let lines = [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"downloading","digest":"sha256:x","total":100,"completed":40}"#,
            #"{"status":"success"}"#,
        ]
        let (session, url) = StubURLProtocol.make { request, body in
            #expect(request.url?.path() == "/api/pull")
            #expect((try? JSONDecoder().decode(JSONValue.self, from: body))?["model"] == "embeddinggemma")
            return .init(body: Data(lines.joined(separator: "\n").utf8))
        }
        let progress = try await OllamaProvider(baseURL: url, session: session).pull("embeddinggemma").collect()
        #expect(progress.map(\.status) == ["pulling manifest", "downloading", "success"])
        #expect(progress[1].fraction == 0.4)

        let (s2, u2) = StubURLProtocol.make { _, _ in .init(body: Data(#"{"error":"pull model manifest: file does not exist"}"#.utf8)) }
        await #expect(throws: ProviderError.server("pull model manifest: file does not exist")) {
            _ = try await OllamaProvider(baseURL: u2, session: s2).pull("nope").collect()
        }
    }
}
