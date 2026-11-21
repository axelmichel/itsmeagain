import CompanionCore
import Foundation
import Tools

/// Feeds and the items fetched from them (30 days), as one JSON file.
public struct NewsLibrary: Codable, Sendable, Hashable {
    public var feeds: [NewsFeed]
    public var items: [NewsItem]

    public init(feeds: [NewsFeed] = NewsFeed.defaults, items: [NewsItem] = []) {
        self.feeds = feeds
        self.items = items
    }

    static let retention: TimeInterval = 30 * 86_400
    static let maxItems = 4_000

    /// Adds new items (dedupe by id and by link), drops what's older than 30 days.
    public mutating func merge(_ fresh: [NewsItem], now: Date = .now) {
        var ids = Set(items.map(\.id))
        var links = Set(items.map(\.link))
        for item in fresh where !ids.contains(item.id) && !links.contains(item.link) {
            // Undated items count as "seen now", so they don't vanish at once or jump to the top later.
            var item = item
            if item.published == .distantPast || item.published > now.addingTimeInterval(86_400) { item.published = now }
            items.append(item)
            ids.insert(item.id)
            links.insert(item.link)
        }
        let cutoff = now.addingTimeInterval(-Self.retention)
        items = Array(items.filter { $0.published >= cutoff }.sorted { $0.published > $1.published }.prefix(Self.maxItems))
    }

    public mutating func addFeed(_ feed: NewsFeed) -> Bool {
        guard !feeds.contains(where: { $0.url == feed.url }) else { return false }
        feeds.append(feed)
        return true
    }

    public mutating func removeFeed(_ url: String) {
        feeds.removeAll { $0.url == url }
        items.removeAll { $0.feedURL == url }
    }
}

public actor NewsFileStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> NewsLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NewsLibrary.self, from: data)
    }

    public func save(_ library: NewsLibrary) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(library).write(to: url, options: [.atomic])
    }
}

// MARK: Ranking

/// Matches items to the user's interests with keywords (local, no model).
public struct NewsRanking: Sendable {
    public struct Topic: Sendable, Hashable {
        public var name: String
        public var keywords: [String]
    }

    public let topics: [Topic]

    /// Topics like "AI / LLMs" or "Swift / iOS / macOS"; extra interests (e.g. from memory) become topics too.
    public init(topics: [String], interests: [String] = []) {
        self.topics = (topics + interests).map { name in
            let parts = name.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            let expanded = parts.flatMap { Self.synonyms[$0] ?? [$0] }
            return Topic(name: name, keywords: Array(Set(expanded)))
        }
    }

    static let synonyms: [String: [String]] = [
        "ai": ["ai", "llm", "llms", "gpt", "claude", "gemini", "gemma", "llama", "qwen", "mistral", "openai", "anthropic", "machine learning", "neural", "agent", "agents", "rag", "embedding", "transformer", "diffusion", "ollama", "hugging face", "model"],
        "llms": ["llm", "llms", "language model", "prompt", "fine-tun", "inference", "tokens", "context window"],
        "swift": ["swift", "swiftui", "swiftdata", "xcode", "concurrency", "actor"],
        "ios": ["ios", "iphone", "ipad", "uikit", "app store", "testflight", "visionos", "watchos"],
        "macos": ["macos", "mac ", "appkit", "apple silicon"],
        "web": ["web", "css", "html", "browser", "chrome", "safari", "firefox", "accessibility", "frontend", "wasm", "webassembly"],
        "js": ["javascript", "js", "node", "deno", "bun", "react", "vue", "svelte", "angular", "next.js", "vite", "npm"],
        "typescript": ["typescript", "ts ", "tsc", "type-safe"],
    ]

    /// The best-matching topic and a score (title matches count more; 0 = unrelated).
    public func classify(_ item: NewsItem) -> (topic: String, score: Int)? {
        let title = " " + item.title.lowercased() + " "
        let summary = " " + item.summary.lowercased() + " "
        var best: (String, Int)?
        for topic in topics {
            var score = 0
            for keyword in topic.keywords {
                if Self.contains(title, keyword) { score += 3 }
                if Self.contains(summary, keyword) { score += 1 }
            }
            if score > (best?.1 ?? 0) { best = (topic.name, score) }
        }
        return best.map { (topic: $0.0, score: $0.1) }
    }

    /// Whole-word-ish match, so "ai" doesn't hit "said" or "maintain".
    static func contains(_ text: String, _ keyword: String) -> Bool {
        guard keyword.count <= 3 else { return text.contains(keyword) }
        return text.range(of: #"(?<![a-z0-9])"# + NSRegularExpression.escapedPattern(for: keyword) + #"(?![a-z0-9])"#, options: .regularExpression) != nil
    }

    /// Items since `since`, grouped by topic in topic order, best first; at most `perTopic` each.
    public func digest(_ items: [NewsItem], since: Date, topic filter: String? = nil, perTopic: Int = 5) -> [(topic: String, items: [NewsItem])] {
        var byTopic: [String: [(NewsItem, Int)]] = [:]
        for item in items where item.published >= since {
            guard let (topic, score) = classify(item), score > 0 else { continue }
            if let filter, !topic.localizedCaseInsensitiveContains(filter) && !item.title.localizedCaseInsensitiveContains(filter) { continue }
            byTopic[topic, default: []].append((item, score))
        }
        return topics.map(\.name).compactMap { name in
            guard let scored = byTopic[name], !scored.isEmpty else { return nil }
            // Score first, then recency; one item per link.
            let sorted = scored.sorted { ($0.1, $0.0.published) > ($1.1, $1.0.published) }.map(\.0)
            return (name, Array(sorted.prefix(perTopic)))
        }
    }
}

// MARK: Tool

/// News is public data, but feed text is written by others: wrapped as untrusted.
public struct NewsTool: Tool {
    public let items: @Sendable () async -> [NewsItem]
    public let ranking: NewsRanking

    public init(ranking: NewsRanking, items: @escaping @Sendable () async -> [NewsItem]) {
        self.ranking = ranking
        self.items = items
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: "news",
            description: "Recent articles from the user's news feeds, matched to their interests (\(ranking.topics.map(\.name).joined(separator: "; "))).",
            parameters: [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "description": "Interest or keyword to filter by (optional)"],
                    "since_hours": ["type": "integer", "description": "How far back (default 24)"],
                    "limit": ["type": "integer", "description": "Items per topic (default 5)"],
                ],
            ]
        )
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let hours = arguments["since_hours"]?.intValue ?? 24
        let limit = min(max(arguments["limit"]?.intValue ?? 5, 1), 15)
        let groups = ranking.digest(await items(), since: .now.addingTimeInterval(-Double(hours) * 3_600), topic: arguments["topic"]?.stringValue, perTopic: limit)
        guard !groups.isEmpty else { return ToolOutput(content: "No matching news in the last \(hours) hours.") }
        var lines: [String] = []
        var sources: [SourceRef] = []
        for group in groups {
            lines.append("## \(group.topic)")
            for item in group.items {
                lines.append("- \(item.title) — \(item.source), \(item.published.formatted(.relative(presentation: .named))) (\(item.link))\n  \(item.summary.prefix(200))")
                sources.append(SourceRef(title: item.title, url: item.link, snippet: item.source))
            }
        }
        return ToolOutput(content: Untrusted.wrap(lines.joined(separator: "\n"), source: "news"), sources: sources)
    }
}
