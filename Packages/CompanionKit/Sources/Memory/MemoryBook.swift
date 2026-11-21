import Accelerate
import Foundation

/// All memory items plus the pure logic around them: matching new facts against what is known,
/// retrieval for a turn, and the core profile for the system prompt.
public struct MemoryBook: Codable, Sendable, Hashable {
    public var items: [MemoryItem]
    /// Per Chat conversation: the highest message order already read for learning.
    public var learnedUpTo: [String: Int]
    /// Learning only reads messages written after this (set when memory first starts), so turning it
    /// on doesn't mine the whole history.
    public var learningSince: Date?

    public init(items: [MemoryItem] = [], learnedUpTo: [String: Int] = [:], learningSince: Date? = nil) {
        self.items = items
        self.learnedUpTo = learnedUpTo
        self.learningSince = learningSince
    }

    public var active: [MemoryItem] { items.filter { $0.status == .active } }
    public var pending: [MemoryItem] { items.filter { $0.status == .pending } }

    public func item(_ id: UUID) -> MemoryItem? { items.first { $0.id == id } }

    // MARK: Matching

    public enum Match: Sendable, Hashable {
        /// Already known (same meaning).
        case duplicate(of: UUID)
        /// Same topic, different content: replaces the old item once confirmed.
        case update(of: UUID)
        case new
    }

    static let duplicateSimilarity: Float = 0.92
    static let updateSimilarity: Float = 0.78

    /// Compares a candidate with active and pending items, by embedding when both have one, else by
    /// normalised words.
    public func match(_ candidate: MemoryCandidate, embedding: [Float]?) -> Match {
        let pool = items.filter { $0.status != .archived }
        let normalized = Self.normalize(candidate.text)
        if let same = pool.first(where: { Self.normalize($0.text) == normalized }) { return .duplicate(of: same.id) }

        var best: (item: MemoryItem, score: Float, byEmbedding: Bool)?
        for item in pool where item.kind == candidate.kind {
            let score: Float
            let byEmbedding: Bool
            if let embedding, let other = item.embedding, other.count == embedding.count {
                score = Self.cosine(embedding, other)
                byEmbedding = true
            } else {
                score = Self.wordOverlap(candidate.text, item.text)
                byEmbedding = false
            }
            if score > (best?.score ?? -1) { best = (item, score, byEmbedding) }
        }
        guard let best else { return .new }
        // Word overlap is coarser than embeddings: lower bars.
        let duplicate = best.byEmbedding ? Self.duplicateSimilarity : 0.85
        let update = best.byEmbedding ? Self.updateSimilarity : 0.5
        if best.score >= duplicate { return .duplicate(of: best.item.id) }
        let sameSubject = candidate.subject.map { subject in
            best.item.subject?.localizedCaseInsensitiveCompare(subject) == .orderedSame
        } ?? false
        if best.score >= update || (sameSubject && best.score >= update * 0.7) { return .update(of: best.item.id) }
        return .new
    }

    // MARK: Changes

    /// Adds an explicit fact right away; an update archives what it replaces.
    @discardableResult
    public mutating func remember(_ candidate: MemoryCandidate, embedding: [Float]?, model: String?, now: Date = .now) -> (item: MemoryItem, match: Match) {
        let match = match(candidate, embedding: embedding)
        switch match {
        case .duplicate(let id):
            let index = items.firstIndex { $0.id == id }!
            items[index].status = .active
            items[index].updatedAt = now
            return (items[index], match)
        case .update(let id):
            archive(id, now: now)
            fallthrough
        case .new:
            var item = MemoryItem(kind: candidate.kind, text: candidate.text, subject: candidate.subject, source: .explicit, sensitive: candidate.sensitive, createdAt: now)
            item.embedding = embedding
            item.embeddingModel = embedding == nil ? nil : model
            items.append(item)
            return (item, match)
        }
    }

    /// A learned candidate: duplicates are dropped, everything else is pending unless its kind is
    /// auto-accepted (never for sensitive items or updates of existing facts). Returns the new item.
    @discardableResult
    public mutating func propose(
        _ candidate: MemoryCandidate, embedding: [Float]?, model: String?, autoAccept: Set<MemoryKind>, now: Date = .now
    ) -> MemoryItem? {
        let match = match(candidate, embedding: embedding)
        if case .duplicate = match { return nil }
        let sensitive = candidate.sensitive || SensitiveGuard.isSensitive(candidate.text)
        var replaces: UUID?
        if case .update(let id) = match { replaces = id }
        let accept = autoAccept.contains(candidate.kind) && !sensitive && replaces == nil
        var item = MemoryItem(
            kind: candidate.kind, text: candidate.text, subject: candidate.subject, source: .learned,
            status: accept ? .active : .pending, sensitive: sensitive, createdAt: now, replaces: replaces
        )
        item.embedding = embedding
        item.embeddingModel = embedding == nil ? nil : model
        items.append(item)
        return item
    }

    /// Accepts a pending item; an update archives the item it replaces.
    public mutating func accept(_ id: UUID, now: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let old = items[index].replaces { archive(old, now: now) }
        items[index].status = .active
        items[index].replaces = nil
        items[index].updatedAt = now
    }

    public mutating func archive(_ id: UUID, now: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .archived
        items[index].updatedAt = now
    }

    public mutating func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func edit(_ id: UUID, text: String, kind: MemoryKind? = nil, now: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].text = text
        if let kind { items[index].kind = kind }
        items[index].embedding = nil
        items[index].embeddingModel = nil
        items[index].updatedAt = now
    }

    public mutating func markUsed(_ ids: [UUID], now: Date = .now) {
        for index in items.indices where ids.contains(items[index].id) { items[index].lastUsedAt = now }
    }

    // MARK: Using memory

    /// Active items matching `query` (words), for /forget and the Memory view search.
    public func search(_ query: String) -> [MemoryItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return active.filter { $0.text.localizedStandardContains(query) || ($0.subject?.localizedStandardContains(query) ?? false) }
    }

    /// The most relevant active items for a message: by embedding when available, else by words.
    public func retrieve(for text: String, embedding: [Float]?, limit: Int = 6, excluding: Set<UUID> = []) -> [MemoryItem] {
        let scored: [(MemoryItem, Float)] = active.filter { !excluding.contains($0.id) }.map { item in
            if let embedding, let other = item.embedding, other.count == embedding.count {
                return (item, Self.cosine(embedding, other))
            }
            return (item, Self.wordOverlap(text, item.text))
        }
        let threshold: Float = embedding == nil ? 0.2 : 0.35
        return scored.filter { $0.1 >= threshold }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Always-included items, most important kinds first, newest within a kind, up to `maxCharacters`.
    public func coreProfile(maxCharacters: Int = 1_800) -> [MemoryItem] {
        let order: [MemoryKind] = [.instruction, .profile, .preference, .person, .routine, .project]
        var used = 0
        var picked: [MemoryItem] = []
        for kind in order {
            for item in active.filter({ $0.kind == kind }).sorted(by: { $0.updatedAt > $1.updatedAt }) {
                let cost = item.text.count + 4
                guard used + cost <= maxCharacters else { continue }
                used += cost
                picked.append(item)
            }
        }
        return picked
    }

    // MARK: Similarity

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = vDSP.dot(a, b)
        let norm = sqrt(vDSP.sumOfSquares(a)) * sqrt(vDSP.sumOfSquares(b))
        return norm > 0 ? dot / norm : 0
    }

    static func normalize(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { ($0.count > 2 || Int($0) != nil) && !stopwords.contains($0) }
    }

    /// Filler that would make unrelated facts look alike ("The user …").
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "user", "users", "user's", "his", "her", "their", "they", "them", "this", "that",
        "when", "what", "where", "who", "how", "does", "did", "are", "was", "has", "have", "from", "into", "about",
        "der", "die", "das", "und", "mit", "für", "fur", "ist", "sind", "ein", "eine", "einen", "nutzer", "benutzer",
        "wann", "was", "wer", "wie", "wo", "auf", "bei", "von", "zum", "zur", "mein", "meine", "ich", "mich", "mir",
    ]

    /// Jaccard overlap of meaningful words (fallback without embeddings).
    static func wordOverlap(_ a: String, _ b: String) -> Float {
        let left = Set(words(a)), right = Set(words(b))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Float(left.intersection(right).count) / Float(left.union(right).count)
    }
}

/// Health, finances, intimate relationships, beliefs and similar: such facts are only stored after
/// review and never shown in notifications.
public enum SensitiveGuard {
    static let terms = [
        // English
        "health", "illness", "disease", "diagnos", "therapy", "therapist", "medication", "medicine", "pregnan", "depress",
        "anxiety", "allerg", "doctor", "hospital", "salary", "income", "debt", "loan", "bank account", "credit card", "iban",
        "password", "pin ", "religio", "church", "political", "party member", "sexual", "divorce", "affair", "lawsuit",
        // German
        "gesundheit", "krankheit", "krank", "diagnose", "therapie", "medikament", "schwanger", "depression", "angst",
        "allergie", "arzt", "ärztin", "krankenhaus", "gehalt", "einkommen", "schulden", "kredit", "konto", "kreditkarte",
        "passwort", "religion", "kirche", "politisch", "partei", "sexuell", "scheidung", "affäre", "klage",
    ]

    public static func isSensitive(_ text: String) -> Bool {
        let lower = text.lowercased() + " "
        return terms.contains { lower.contains($0) }
    }
}
