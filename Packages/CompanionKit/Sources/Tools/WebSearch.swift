import CompanionCore
import Foundation
import SwiftSoup

public struct SearchResult: Sendable, Hashable {
    public var title: String
    public var url: String
    public var snippet: String
}

public protocol SearchBackend: Sendable {
    var name: String { get }
    /// Advice for the model on phrasing queries for this backend.
    var queryHint: String { get }
    func search(_ query: String, count: Int) async throws -> [SearchResult]
}

extension SearchBackend {
    public var queryHint: String { "" }
}

public struct WebSearchTool: Tool {
    public let backend: any SearchBackend
    /// Used when `backend` fails (e.g. a self-hosted instance that is offline).
    public let fallback: (any SearchBackend)?
    public let maxResults: Int

    public init(backend: any SearchBackend, fallback: (any SearchBackend)? = nil, maxResults: Int = 6) {
        self.backend = backend
        self.fallback = fallback
        self.maxResults = maxResults
    }

    /// The query goes to the search backend.
    public var sendsDataExternally: Bool { true }

    public var spec: ToolSpec {
        ToolSpec(
            name: "web_search",
            description: """
                Search the web (\(backend.name)). Returns titles, URLs and snippets. Use it for facts, \
                current information and comparisons, then read the most relevant results with fetch_page.\(backend.queryHint.isEmpty ? "" : " " + backend.queryHint)\(fallback.map { " If \(backend.name) is unavailable, \($0.name) is searched instead." } ?? "")
                """,
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "Search query"]],
                "required": ["query"],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let query = try arguments.requiredString("query")
        var note = ""
        let results: [SearchResult]
        do {
            results = try await backend.search(query, count: maxResults)
        } catch {
            guard let fallback, !(error is CancellationError) else { throw error }
            note = "Note: \(backend.name) is unavailable (\(error.localizedDescription)); these results come from \(fallback.name). \(fallback.queryHint)\n\n"
            results = try await fallback.search(query, count: maxResults)
        }
        guard !results.isEmpty else { return ToolOutput(content: note + "No results for “\(query)”.") }
        let listing = results.enumerated().map { index, result in
            "[\(index + 1)] \(result.title)\n\(result.url)\n\(result.snippet)"
        }
        return ToolOutput(
            content: note + listing.joined(separator: "\n\n"),
            sources: results.map { SourceRef(title: $0.title, url: $0.url, snippet: $0.snippet) }
        )
    }
}

// MARK: - Backends

enum SearchHTTP {
    static let userAgent = "ItsMeAgain/0.1 (macOS; local AI companion)"

    static func get(_ url: URL, headers: [String: String] = [:], session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return try await send(request, session: session)
    }

    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ToolError.failed("Search failed: no HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolError.failed("Search failed (HTTP \(http.statusCode)).")
        }
        return data
    }

    /// Search APIs often wrap matches in `<strong>`/`<span>`; the model wants plain text.
    static func plainText(_ html: String) -> String {
        ((try? SwiftSoup.parseBodyFragment(html).text()) ?? html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keyless default. Only covers encyclopedic knowledge, but always works.
public struct WikipediaSearchBackend: SearchBackend {
    public let language: String
    private let host: String
    private let session: URLSession

    public init(language: String = "en", session: URLSession = .shared) {
        self.init(language: language, host: "\(language).wikipedia.org", session: session)
    }

    init(language: String, host: String, session: URLSession) {
        self.language = language
        self.host = host
        self.session = session
    }

    public var name: String { "Wikipedia" }
    public var queryHint: String {
        "This is Wikipedia full-text search: use 2–4 keywords naming the topic (e.g. “Swift programming language”), never a full question."
    }

    public func search(_ query: String, count: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://\(host)/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "list", value: "search"),
            .init(name: "srsearch", value: query), .init(name: "srlimit", value: String(count)),
            .init(name: "format", value: "json"), .init(name: "utf8", value: "1"),
        ]
        let json = try JSONDecoder().decode(JSONValue.self, from: try await SearchHTTP.get(components.url!, session: session))
        guard case .array(let hits)? = json["query"]?["search"] else { return [] }
        return hits.compactMap { hit in
            guard let title = hit["title"]?.stringValue else { return nil }
            let slug = title.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            return SearchResult(
                title: title,
                url: "https://\(language).wikipedia.org/wiki/\(slug)",
                snippet: SearchHTTP.plainText(hit["snippet"]?.stringValue ?? "")
            )
        }
    }
}

/// Self-hosted metasearch (local-first). The instance must allow `format=json` (settings.yml → search.formats).
public struct SearXNGBackend: SearchBackend {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public var name: String { "SearXNG" }

    public func search(_ query: String, count: Int) async throws -> [SearchResult] {
        var components = URLComponents(url: baseURL.appending(path: "search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "q", value: query), .init(name: "format", value: "json")]
        let data: Data
        do {
            data = try await SearchHTTP.get(components.url!, session: session)
        } catch ToolError.failed(let message) where message.contains("403") {
            throw ToolError.failed("SearXNG refused JSON output; enable `json` under search.formats in its settings.yml.")
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let results)? = json["results"] else { return [] }
        return results.prefix(count).compactMap { result in
            guard let url = result["url"]?.stringValue else { return nil }
            return SearchResult(
                title: result["title"]?.stringValue ?? url,
                url: url,
                snippet: SearchHTTP.plainText(result["content"]?.stringValue ?? "")
            )
        }
    }
}

/// Brave Search API (free tier available). https://brave.com/search/api/
public struct BraveSearchBackend: SearchBackend {
    public let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.search.brave.com/res/v1/web/search")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.session = session
    }

    public var name: String { "Brave Search" }

    public func search(_ query: String, count: Int) async throws -> [SearchResult] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "q", value: query), .init(name: "count", value: String(count))]
        let data = try await SearchHTTP.get(
            components.url!,
            headers: ["X-Subscription-Token": apiKey, "Accept": "application/json"],
            session: session
        )
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let results)? = json["web"]?["results"] else { return [] }
        return results.compactMap { result in
            guard let url = result["url"]?.stringValue else { return nil }
            return SearchResult(
                title: SearchHTTP.plainText(result["title"]?.stringValue ?? url),
                url: url,
                snippet: SearchHTTP.plainText(result["description"]?.stringValue ?? "")
            )
        }
    }
}

/// Ollama's hosted web search (needs an ollama.com API key).
public struct OllamaWebSearchBackend: SearchBackend {
    public let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(apiKey: String, endpoint: URL = URL(string: "https://ollama.com/api/web_search")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.session = session
    }

    public var name: String { "Ollama Web Search" }

    public func search(_ query: String, count: Int) async throws -> [SearchResult] {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["query": JSONValue.string(query), "max_results": .number(Double(count))])
        let json = try JSONDecoder().decode(JSONValue.self, from: try await SearchHTTP.send(request, session: session))
        guard case .array(let results)? = json["results"] else { return [] }
        return results.compactMap { result in
            guard let url = result["url"]?.stringValue else { return nil }
            let content = result["content"]?.stringValue ?? ""
            return SearchResult(title: result["title"]?.stringValue ?? url, url: url, snippet: String(content.prefix(400)))
        }
    }
}
