import Foundation
import SwiftSoup

public struct NewsFeed: Codable, Sendable, Hashable, Identifiable {
    public var url: String
    public var title: String
    public var enabled: Bool
    public var etag: String?
    public var lastModified: String?
    public var lastFetched: Date?
    public var lastError: String?

    public var id: String { url }

    public init(url: String, title: String, enabled: Bool = true) {
        self.url = url
        self.title = title
        self.enabled = enabled
    }

    /// Sources daily.dev aggregates, for the default interests (checked reachable 2026-11-21).
    public static let defaults: [NewsFeed] = [
        // Swift / iOS / macOS
        NewsFeed(url: "https://www.hackingwithswift.com/articles/rss", title: "Hacking with Swift"),
        NewsFeed(url: "https://www.swiftbysundell.com/rss", title: "Swift by Sundell"),
        NewsFeed(url: "https://www.avanderlee.com/feed/", title: "SwiftLee"),
        NewsFeed(url: "https://www.donnywals.com/feed/", title: "Donny Wals"),
        NewsFeed(url: "https://developer.apple.com/news/rss/news.rss", title: "Apple Developer News"),
        NewsFeed(url: "https://iosdevweekly.com/issues.rss", title: "iOS Dev Weekly"),
        // Web / JS / TypeScript
        NewsFeed(url: "https://devblogs.microsoft.com/typescript/feed/", title: "TypeScript Blog"),
        NewsFeed(url: "https://web.dev/static/blog/feed.xml", title: "web.dev"),
        NewsFeed(url: "https://css-tricks.com/feed/", title: "CSS-Tricks"),
        NewsFeed(url: "https://www.smashingmagazine.com/feed/", title: "Smashing Magazine"),
        NewsFeed(url: "https://javascriptweekly.com/rss/", title: "JavaScript Weekly"),
        NewsFeed(url: "https://overreacted.io/rss.xml", title: "overreacted"),
        NewsFeed(url: "https://react.dev/rss.xml", title: "React Blog"),
        NewsFeed(url: "https://github.blog/feed/", title: "GitHub Blog"),
        // AI / LLMs
        NewsFeed(url: "https://simonwillison.net/atom/everything/", title: "Simon Willison"),
        NewsFeed(url: "https://huggingface.co/blog/feed.xml", title: "Hugging Face"),
        NewsFeed(url: "https://openai.com/news/rss.xml", title: "OpenAI News"),
        NewsFeed(url: "https://blog.google/technology/ai/rss/", title: "Google AI"),
        NewsFeed(url: "https://ollama.com/blog/rss.xml", title: "Ollama"),
        NewsFeed(url: "https://www.latent.space/feed", title: "Latent Space"),
    ]
}

public struct NewsItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var feedURL: String
    public var source: String
    public var title: String
    public var link: String
    public var published: Date
    /// Plain text, at most 600 characters.
    public var summary: String

    public init(id: String, feedURL: String, source: String, title: String, link: String, published: Date, summary: String) {
        self.id = id
        self.feedURL = feedURL
        self.source = source
        self.title = title
        self.link = link
        self.published = published
        self.summary = summary
    }
}

// MARK: Parsing

/// RSS 2.0, RSS 1.0 (RDF) and Atom.
public enum FeedParser {
    public struct Document: Sendable {
        public var title: String
        public var items: [NewsItem]
    }

    public static func parse(_ data: Data, feedURL: String, fallbackTitle: String = "") -> Document? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !delegate.entries.isEmpty else { return nil }
        guard delegate.sawFeed else { return nil }
        let source = delegate.feedTitle.isEmpty ? fallbackTitle : delegate.feedTitle
        let items = delegate.entries.compactMap { entry -> NewsItem? in
            let title = clean(entry["title"] ?? "")
            let link = (entry["link"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, link.lowercased().hasPrefix("http") else { return nil }
            let dateText = entry["pubDate"] ?? entry["published"] ?? entry["updated"] ?? entry["dc:date"] ?? ""
            let summaryHTML = entry["description"] ?? entry["summary"] ?? entry["content:encoded"] ?? entry["content"] ?? ""
            let guid = (entry["guid"] ?? entry["id"] ?? link).trimmingCharacters(in: .whitespacesAndNewlines)
            return NewsItem(
                id: guid.isEmpty ? link : guid, feedURL: feedURL, source: source, title: title, link: link,
                published: date(dateText) ?? .distantPast, summary: String(text(summaryHTML).prefix(600))
            )
        }
        return Document(title: source, items: items)
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var sawFeed = false
        var feedTitle = ""
        var entries: [[String: String]] = []
        private var current: [String: String]?
        private var stack: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let element = name
            if ["rss", "feed", "rdf:RDF"].contains(element) { sawFeed = true }
            if element == "item" || element == "entry" { current = [:] }
            // Atom: <link rel="alternate" href="…"/>
            if element == "link", current != nil, let href = attributes["href"] {
                let rel = attributes["rel"] ?? "alternate"
                if rel == "alternate", current?["link"] == nil { current?["link"] = href }
            }
            stack.append(element)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            text += String(decoding: block, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let element = name
            stack.removeLast()
            if element == "item" || element == "entry" {
                if let current { entries.append(current) }
                current = nil
            } else if current != nil {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, current?[element] == nil { current?[element] = value }
            } else if element == "title", feedTitle.isEmpty, stack.last == "channel" || stack.last == "feed" {
                feedTitle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = ""
        }
    }

    static func clean(_ text: String) -> String {
        Self.text(text).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTML (or plain text) → plain text.
    static func text(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html.trimmingCharacters(in: .whitespacesAndNewlines) }
        let plain = (try? SwiftSoup.parse(html).text()) ?? html
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Feed URLs from an OPML export (feed readers, daily.dev-style source lists).
public enum OPMLImport {
    public static func feeds(_ data: Data) -> [NewsFeed] {
        final class Delegate: NSObject, XMLParserDelegate {
            var feeds: [NewsFeed] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                guard name == "outline", let url = attributes["xmlUrl"], url.lowercased().hasPrefix("http") else { return }
                feeds.append(NewsFeed(url: url, title: attributes["title"] ?? attributes["text"] ?? url))
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        var seen = Set<String>()
        return delegate.feeds.filter { seen.insert($0.url).inserted }
    }
}

// MARK: Fetching

public enum FeedFetcher {
    public enum Result: Sendable {
        case updated(title: String, items: [NewsItem], etag: String?, lastModified: String?)
        case unchanged
    }

    /// Conditional GET (ETag / Last-Modified); only http(s); newest 60 items.
    public static func fetch(_ feed: NewsFeed, session: URLSession = .shared) async throws -> Result {
        guard let url = URL(string: feed.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("ItsMeAgain/1.0 (+RSS reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let etag = feed.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified = feed.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304 { return .unchanged }
        guard let http, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http?.statusCode ?? 0)"])
        }
        guard let document = FeedParser.parse(data, feedURL: feed.url, fallbackTitle: feed.title) else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "Not an RSS or Atom feed"])
        }
        let items = document.items.sorted { $0.published > $1.published }.prefix(60)
        return .updated(
            title: document.title, items: Array(items),
            etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }
}
