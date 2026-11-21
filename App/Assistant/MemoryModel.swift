import CompanionCore
import Foundation
import Memory
import Observation
import Persistence
import Routing
import SwiftData

/// The personal memory: a JSON file next to the conversations, used only by Chat-mode turns on
/// local models. Learns from the user's own words in idle Chat conversations.
@MainActor
@Observable
final class MemoryModel {
    static let idleBeforeLearning: TimeInterval = 10 * 60
    static let learningInterval: TimeInterval = 120

    private(set) var book = MemoryBook()
    private(set) var isLearning = false
    var learningEnabled: Bool = UserDefaults.standard.object(forKey: "memoryLearning") as? Bool ?? true {
        didSet { UserDefaults.standard.set(learningEnabled, forKey: "memoryLearning") }
    }
    var autoAccept: Set<MemoryKind> = Set(
        (UserDefaults.standard.stringArray(forKey: "memoryAutoAccept") ?? MemoryKind.defaultAutoAccept.map(\.rawValue)).compactMap(MemoryKind.init(rawValue:))
    ) {
        didSet { UserDefaults.standard.set(autoAccept.map(\.rawValue), forKey: "memoryAutoAccept") }
    }

    @ObservationIgnored private let store = MemoryFileStore(url: AppData.memory)
    @ObservationIgnored private var timer: Timer?
    /// The local Chat model and the embedder, from the app's settings.
    @ObservationIgnored var chatModel: () throws -> (provider: any LLMProvider, model: String) = { throw ProviderError.unavailable("No model") }
    @ObservationIgnored var embedder: () -> (embedder: any Embedder, model: String)? = { nil }
    @ObservationIgnored var onLearned: (_ pending: Int) -> Void = { _ in }

    init() {}

    func load() async {
        book = await store.load()
        if book.learningSince == nil { change { $0.learningSince = .now } }
        await backfillEmbeddings()
    }

    private func save() {
        let snapshot = book
        Task { try? await store.save(snapshot) }
    }

    private func change(_ update: (inout MemoryBook) -> Void) {
        update(&book)
        save()
    }

    // MARK: Editing

    func accept(_ id: UUID) { change { $0.accept(id) } }
    func archive(_ id: UUID) { change { $0.archive(id) } }
    func delete(_ id: UUID) { change { $0.delete(id) } }
    func restore(_ id: UUID) { change { $0.accept(id) } }

    func edit(_ id: UUID, text: String, kind: MemoryKind? = nil) {
        change { $0.edit(id, text: text, kind: kind) }
        Task { await backfillEmbeddings() }
    }

    /// An explicit fact (/remember, the Memory view, an approved `remember` call): classified by the
    /// local model, stored as active right away.
    func rememberFact(_ fact: String) async throws -> (item: MemoryItem, match: MemoryBook.Match) {
        var candidate = MemoryCandidate(kind: .preference, text: fact, sensitive: SensitiveGuard.isSensitive(fact))
        if let (provider, model) = try? chatModel(),
            let classified = try? await MemoryExtractor.classify(fact, provider: provider, model: model)
        {
            candidate = classified
        }
        let (vector, model) = await embed(candidate.text)
        var result: (item: MemoryItem, match: MemoryBook.Match)!
        change { result = $0.remember(candidate, embedding: vector, model: model) }
        return result
    }

    func add(_ text: String, kind: MemoryKind) async {
        let candidate = MemoryCandidate(kind: kind, text: text, sensitive: SensitiveGuard.isSensitive(text))
        let (vector, model) = await embed(text)
        change { $0.remember(candidate, embedding: vector, model: model) }
    }

    // MARK: Using memory

    /// The memory section for a Chat turn: core profile plus items relevant to `text`. Only for local
    /// providers; nil when there is nothing to say.
    func context(for text: String, providerIsLocal: Bool) async -> String? {
        guard providerIsLocal, !book.active.isEmpty else { return nil }
        let core = book.coreProfile()
        let (vector, _) = await embed(text, timeout: .seconds(3))
        let relevant = book.retrieve(for: text, embedding: vector, excluding: Set(core.map(\.id)))
        if !relevant.isEmpty { change { $0.markUsed(relevant.map(\.id)) } }
        return MemoryContext.section(core: core, relevant: relevant, providerIsLocal: providerIsLocal)
    }

    func recall(_ query: String) async -> [MemoryItem] {
        let words = book.search(query)
        let (vector, _) = await embed(query, timeout: .seconds(3))
        let similar = book.retrieve(for: query, embedding: vector, limit: 8)
        var seen = Set<UUID>()
        return (words + similar).filter { seen.insert($0.id).inserted }
    }

    // MARK: Embeddings

    /// Nil when no embedding model is reachable; memory then falls back to word matching.
    private func embed(_ text: String, timeout: Duration = .seconds(15)) async -> ([Float]?, String?) {
        guard let (embedder, model) = embedder() else { return (nil, nil) }
        let vector = try? await withThrowingTaskGroup(of: [Float]?.self) { group in
            group.addTask { try await embedder.embed([text]).first }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return (vector, vector == nil ? nil : model)
    }

    /// Items without an embedding for the current model get one (after edits, or a model change).
    func backfillEmbeddings() async {
        guard let (_, model) = embedder() else { return }
        for item in book.items where item.status != .archived && item.embeddingModel != model {
            let (vector, used) = await embed(item.text)
            guard let vector else { return }  // embedder unreachable: try again later
            change { book in
                guard let index = book.items.firstIndex(where: { $0.id == item.id }) else { return }
                book.items[index].embedding = vector
                book.items[index].embeddingModel = used
            }
        }
    }

    // MARK: Learning

    func startLearning(container: ModelContainer, isBusy: @escaping @MainActor () -> Bool) {
        timer = Timer.scheduledTimer(withTimeInterval: Self.learningInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.learningEnabled, !self.isLearning, !isBusy() else { return }
                Task { await self.learnFromIdleConversations(context: container.mainContext) }
            }
        }
    }

    /// Chat conversations idle for 10 minutes with new user messages since the last pass. Only the
    /// user's own messages are read.
    func learnFromIdleConversations(context: ModelContext, now: Date = .now) async {
        guard let (provider, model) = try? chatModel() else { return }
        let chat = TaskKind.chat.rawValue
        let cutoff = now.addingTimeInterval(-Self.idleBeforeLearning)
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.taskRaw == chat && $0.updatedAt < cutoff },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let conversations = try? context.fetch(descriptor) else { return }
        isLearning = true
        defer { isLearning = false }
        var proposed = 0
        var processed = 0
        for conversation in conversations where processed < 3 {
            let key = conversation.id.uuidString
            let done = book.learnedUpTo[key] ?? -1
            let since = book.learningSince ?? now
            let fresh = conversation.orderedMessages.filter { $0.order > done && $0.createdAt >= since }
            guard let last = fresh.last?.order else { continue }
            processed += 1
            let messages = MemoryExtractor.userText(fresh.map { ($0.role, $0.content) })
            if !messages.isEmpty,
                let candidates = try? await MemoryExtractor.extract(from: messages, known: book.active, provider: provider, model: model)
            {
                for candidate in candidates {
                    let (vector, used) = await embed(candidate.text)
                    var added: MemoryItem?
                    change { added = $0.propose(candidate, embedding: vector, model: used, autoAccept: autoAccept) }
                    if added?.status == .pending { proposed += 1 }
                }
            } else if !messages.isEmpty {
                continue  // model unavailable: try this conversation again next time
            }
            change { $0.learnedUpTo[key] = last }
        }
        if proposed > 0 { onLearned(book.pending.count) }
    }
}

extension MemoryModel: MemoryAccess {
    func remember(_ fact: String) async throws -> MemoryItem {
        try await rememberFact(fact).item
    }
}
