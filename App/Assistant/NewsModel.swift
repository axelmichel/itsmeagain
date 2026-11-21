import Foundation
import Memory
import News
import Observation

/// News feeds, refreshed hourly (and before /news when stale). Kept in News.json next to the store.
@MainActor
@Observable
final class NewsModel {
    static let refreshInterval: TimeInterval = 60 * 60
    static let staleAfter: TimeInterval = 30 * 60

    private(set) var library = NewsLibrary()
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    @ObservationIgnored private let store = NewsFileStore(url: AppData.news)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var interests: () -> (topics: [String], extra: [String]) = { (NewsDigestDefaults.topics, []) }

    var ranking: NewsRanking {
        let (topics, extra) = interests()
        return NewsRanking(topics: topics, interests: extra)
    }

    func start() {
        Task {
            if let saved = await store.load() { library = saved }
            lastRefresh = library.feeds.compactMap(\.lastFetched).max()
            await refreshIfStale()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
    }

    func refreshIfStale() async {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < Self.staleAfter { return }
        await refresh()
    }

    /// Fetches every enabled feed in parallel; one failing feed never blocks the others.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let feeds = library.feeds.filter(\.enabled)
        let results = await withTaskGroup(of: (String, Result<FeedFetcher.Result, Error>).self) { group in
            for feed in feeds {
                group.addTask {
                    do { return (feed.url, .success(try await FeedFetcher.fetch(feed))) } catch { return (feed.url, .failure(error)) }
                }
            }
            var all: [(String, Result<FeedFetcher.Result, Error>)] = []
            for await result in group { all.append(result) }
            return all
        }
        let now = Date.now
        for (url, result) in results {
            guard let index = library.feeds.firstIndex(where: { $0.url == url }) else { continue }
            library.feeds[index].lastFetched = now
            switch result {
            case .success(.updated(_, let items, let etag, let lastModified)):
                library.feeds[index].etag = etag
                library.feeds[index].lastModified = lastModified
                library.feeds[index].lastError = nil
                library.merge(items, now: now)
            case .success(.unchanged):
                library.feeds[index].lastError = nil
            case .failure(let error):
                library.feeds[index].lastError = error.localizedDescription
            }
        }
        lastRefresh = now
        save()
    }

    // MARK: Feeds

    /// Checks the URL is a working feed before adding it.
    func addFeed(_ urlString: String) async throws -> NewsFeed {
        var feed = NewsFeed(url: urlString.trimmingCharacters(in: .whitespacesAndNewlines), title: urlString)
        guard case .updated(let title, let items, let etag, let lastModified) = try await FeedFetcher.fetch(feed) else {
            throw URLError(.cannotParseResponse)
        }
        feed.title = title.isEmpty ? (URL(string: feed.url)?.host() ?? feed.url) : title
        feed.etag = etag
        feed.lastModified = lastModified
        feed.lastFetched = .now
        guard library.addFeed(feed) else { throw URLError(.cannotCreateFile, userInfo: [NSLocalizedDescriptionKey: "That feed is already in your list."]) }
        library.merge(items)
        save()
        return feed
    }

    func importOPML(_ data: Data) -> Int {
        let added = OPMLImport.feeds(data).filter { library.addFeed($0) }.count
        save()
        if added > 0 { Task { await refresh() } }
        return added
    }

    func setEnabled(_ url: String, _ enabled: Bool) {
        guard let index = library.feeds.firstIndex(where: { $0.url == url }) else { return }
        library.feeds[index].enabled = enabled
        save()
    }

    func remove(_ url: String) {
        library.removeFeed(url)
        save()
    }

    func restoreDefaults() {
        for feed in NewsFeed.defaults { _ = library.addFeed(feed) }
        save()
        Task { await refresh() }
    }

    private func save() {
        let snapshot = library
        Task { try? await store.save(snapshot) }
    }

    // MARK: Output

    /// `/news`: top items of the last day per interest, as Markdown with links.
    func markdown(topic: String?, hours: Int = 24) -> String {
        let groups = ranking.digest(library.items, since: .now.addingTimeInterval(-Double(hours) * 3_600), topic: topic, perTopic: 5)
        guard !groups.isEmpty else {
            let failing = library.feeds.filter { $0.enabled && $0.lastError != nil }.count
            return "No matching news in the last \(hours) hours" + (topic.map { " for “\($0)”" } ?? "") + "."
                + (failing > 0 ? " (\(failing) feeds couldn't be loaded — Settings → Assistant → News.)" : "")
        }
        return groups.map { group in
            "### \(group.topic)\n" + group.items.map { item in
                let title = item.title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
                return "- [\(title)](\(item.link)) — _\(item.source), \(item.published.formatted(.relative(presentation: .named)))_"
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

enum NewsDigestDefaults {
    static let topics = ["AI / LLMs", "Swift / iOS / macOS", "Web / JS / TypeScript"]
}
