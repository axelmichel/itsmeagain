import CompanionCore
import Foundation
import Tools

/// Semantic search over the user's indexed folders.
public struct SearchDocumentsTool: Tool {
    public let store: KnowledgeStore
    public let embedder: any Embedder
    public let embeddingModel: String
    /// Folder names, so the model knows what it can search.
    public let collections: [String]
    public var limit = 6

    public init(store: KnowledgeStore, embedder: any Embedder, embeddingModel: String, collections: [String]) {
        self.store = store
        self.embedder = embedder
        self.embeddingModel = embeddingModel
        self.collections = collections
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "search_documents",
            description: """
                Search the user's own files (indexed folders: \(collections.joined(separator: ", "))). Returns the most \
                relevant passages with their file paths. Use it whenever the answer may be in the user's notes or documents. \
                Phrase the query as a description of the information you need.
                """,
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "What to look for"]],
                "required": ["query"],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let query = try arguments.requiredString("query")
        guard await store.embeddingModel == embeddingModel, await store.chunkCount > 0 else {
            throw ToolError.failed("The document index is empty or was built with another embedding model; reindex in Settings → Knowledge.")
        }
        guard let vector = try await embedder.embed([EmbeddingStyle.forModel(embeddingModel).query(query)]).first else {
            throw ToolError.failed("The embedding model returned nothing.")
        }
        let hits = await store.search(vector, limit: limit)
        guard !hits.isEmpty else { return ToolOutput(content: "No matching passages.") }

        let listing = hits.enumerated().map { index, hit in
            "[\(index + 1)] \(hit.chunk.title) — \(hit.chunk.path)\n\(hit.chunk.text)"
        }
        var seen: Set<String> = []
        let sources = hits.compactMap { hit -> SourceRef? in
            guard seen.insert(hit.chunk.path).inserted else { return nil }
            return SourceRef(
                title: hit.chunk.title,
                url: URL(filePath: hit.chunk.path).absoluteString,
                snippet: String(hit.chunk.text.prefix(200))
            )
        }
        return ToolOutput(content: listing.joined(separator: "\n\n"), sources: sources)
    }
}
