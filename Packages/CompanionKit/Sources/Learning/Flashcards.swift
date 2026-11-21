import CompanionCore
import Foundation

/// One vocabulary card with its review schedule.
public struct Flashcard: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The language being learned ("French").
    public var language: String
    /// The word or phrase, with article / gender where the language has them ("la boulangerie").
    public var front: String
    /// The meaning in the user's language.
    public var back: String
    public var partOfSpeech: String
    public var example: String
    public var exampleTranslation: String
    public var notes: String
    public var created: Date

    // Spaced repetition (SM-2 style).
    public var due: Date
    /// Days until the next review after a correct answer.
    public var interval: Double
    public var ease: Double
    public var reviews: Int
    public var lapses: Int

    public init(
        id: UUID = UUID(), language: String, front: String, back: String, partOfSpeech: String = "", example: String = "",
        exampleTranslation: String = "", notes: String = "", created: Date = .now
    ) {
        self.id = id
        self.language = language
        self.front = front
        self.back = back
        self.partOfSpeech = partOfSpeech
        self.example = example
        self.exampleTranslation = exampleTranslation
        self.notes = notes
        self.created = created
        due = created
        interval = 0
        ease = 2.5
        reviews = 0
        lapses = 0
    }

    public var isNew: Bool { reviews == 0 }
}

public enum ReviewGrade: Int, Codable, Sendable, CaseIterable {
    case again, hard, good, easy

    public var title: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}

/// All cards, as one JSON file.
public struct FlashcardDeck: Codable, Sendable, Hashable {
    public var cards: [Flashcard]

    public init(cards: [Flashcard] = []) {
        self.cards = cards
    }

    public var languages: [String] {
        Array(Set(cards.map(\.language))).sorted()
    }

    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }

    /// Adds a card; the same word in the same language updates the existing card (its schedule stays).
    @discardableResult
    public mutating func add(_ card: Flashcard) -> (card: Flashcard, isNew: Bool) {
        if let index = cards.firstIndex(where: { $0.language == card.language && Self.key($0.front) == Self.key(card.front) }) {
            var updated = card
            updated.id = cards[index].id
            updated.created = cards[index].created
            updated.due = cards[index].due
            updated.interval = cards[index].interval
            updated.ease = cards[index].ease
            updated.reviews = cards[index].reviews
            updated.lapses = cards[index].lapses
            cards[index] = updated
            return (updated, false)
        }
        cards.append(card)
        return (card, true)
    }

    public mutating func remove(_ id: UUID) {
        cards.removeAll { $0.id == id }
    }

    /// Cards for a session: due ones first (most overdue first), then new ones, up to `limit`.
    public func session(limit: Int, language: String? = nil, now: Date = .now) -> [Flashcard] {
        let pool = cards.filter { language == nil || $0.language.localizedCaseInsensitiveCompare(language!) == .orderedSame }
        let due = pool.filter { !$0.isNew && $0.due <= now }.sorted { $0.due < $1.due }
        let new = pool.filter(\.isNew).sorted { $0.created < $1.created }
        return Array((due + new).prefix(max(limit, 1)))
    }

    public func dueCount(language: String? = nil, now: Date = .now) -> Int {
        cards.filter { (language == nil || $0.language == language) && $0.due <= now }.count
    }

    /// Records an answer and schedules the next review.
    @discardableResult
    public mutating func grade(_ id: UUID, _ grade: ReviewGrade, now: Date = .now) -> Flashcard? {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return nil }
        cards[index] = Self.schedule(cards[index], grade, now: now)
        return cards[index]
    }

    static func schedule(_ card: Flashcard, _ grade: ReviewGrade, now: Date) -> Flashcard {
        var card = card
        card.reviews += 1
        switch grade {
        case .again:
            card.lapses += card.interval > 0 ? 1 : 0
            card.interval = 0
            card.ease = max(1.3, card.ease - 0.2)
            card.due = now.addingTimeInterval(10 * 60)  // again in this or the next session
        case .hard:
            card.interval = card.interval == 0 ? 1 : max(1, card.interval * 1.2)
            card.ease = max(1.3, card.ease - 0.15)
        case .good:
            card.interval = card.interval == 0 ? 1 : (card.interval < 2 ? 3 : card.interval * card.ease)
        case .easy:
            card.interval = card.interval == 0 ? 4 : card.interval * card.ease * 1.3
            card.ease += 0.15
        }
        if grade != .again {
            card.due = now.addingTimeInterval(card.interval * 86_400)
        }
        return card
    }
}

public actor FlashcardFileStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> FlashcardDeck {
        guard let data = try? Data(contentsOf: url) else { return FlashcardDeck() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(FlashcardDeck.self, from: data)) ?? FlashcardDeck()
    }

    public func save(_ deck: FlashcardDeck) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(deck).write(to: url, options: [.atomic])
    }
}

// MARK: Making cards and checking text (local model)

public enum FlashcardMaker {
    private struct Reply: Decodable {
        var language: String
        var word: String
        var translation: String
        var part_of_speech: String
        var example: String
        var example_translation: String
        var notes: String
    }

    /// "boulangerie" → a card; `language` is the language to learn (detected when nil), `explainIn` the user's.
    public static func make(
        _ word: String, language: String?, explainIn: String, provider: any LLMProvider, model: String
    ) async throws -> Flashcard {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "language": ["type": "string"], "word": ["type": "string"], "translation": ["type": "string"],
                "part_of_speech": ["type": "string"], "example": ["type": "string"], "example_translation": ["type": "string"],
                "notes": ["type": "string"],
            ],
            "required": ["language", "word", "translation", "part_of_speech", "example", "example_translation", "notes"],
        ]
        let target = language.map { "The word is to be learned in \($0); if it is given in another language, use its \($0) equivalent." }
            ?? "Detect the language of the word."
        let system = """
            You make a vocabulary flashcard. \(target) Fields:
            - language: the language being learned, as an English name (e.g. "French").
            - word: the dictionary form in that language, with the article or gender for nouns (e.g. "la boulangerie").
            - translation: the meaning(s) in \(explainIn), short, most common first.
            - part_of_speech: in \(explainIn).
            - example: one natural, everyday sentence in the learned language using the word.
            - example_translation: that sentence in \(explainIn).
            - notes: one short hint in \(explainIn) (irregular forms, false friends, register), or "".
            Be correct; if unsure about a meaning, give the common one only.
            """
        let reply = try await StructuredCompletion.json(Reply.self, provider: provider, model: model, system: system, user: word, schema: schema, maxTokens: 500)
        let front = reply.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !reply.translation.isEmpty else { throw ProviderError.invalidResponse("no card for “\(word)”") }
        return Flashcard(
            language: (language ?? reply.language).trimmingCharacters(in: .whitespaces).capitalized, front: front,
            back: reply.translation.trimmingCharacters(in: .whitespacesAndNewlines), partOfSpeech: reply.part_of_speech,
            example: reply.example, exampleTranslation: reply.example_translation, notes: reply.notes
        )
    }
}

/// A problem found in a text: where it is (exact substring), what to write instead, why.
public struct SpellingIssue: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case spelling, grammar, style }

    public var id: String { "\(location):\(text)" }
    /// UTF-16 offset of `text` in the checked text.
    public var location: Int
    public var text: String
    public var correction: String
    public var kind: Kind
    public var explanation: String

    public init(location: Int, text: String, correction: String, kind: Kind, explanation: String) {
        self.location = location
        self.text = text
        self.correction = correction
        self.kind = kind
        self.explanation = explanation
    }
}

public struct SpellingResult: Codable, Sendable, Hashable {
    public var text: String
    public var language: String
    public var issues: [SpellingIssue]
    public var corrected: String
}

public enum SpellingChecker {
    private struct Reply: Decodable {
        struct Issue: Decodable {
            var text: String
            var correction: String
            var kind: String
            var explanation: String
        }
        var language: String
        var corrected: String
        var issues: [Issue]
    }

    /// Model check (grammar, word choice, spelling), merged with deterministic spelling issues
    /// (e.g. from macOS's spell checker). Model issues only count when their text really occurs.
    public static func check(
        _ text: String, spelling: [SpellingIssue], explainIn: String, provider: any LLMProvider, model: String
    ) async throws -> SpellingResult {
        let schema: JSONValue = [
            "type": "object",
            "properties": [
                "language": ["type": "string"], "corrected": ["type": "string"],
                "issues": ["type": "array", "items": ["type": "object", "properties": [
                    "text": ["type": "string"], "correction": ["type": "string"],
                    "kind": ["type": "string", "enum": ["spelling", "grammar", "style"]], "explanation": ["type": "string"],
                ], "required": ["text", "correction", "kind", "explanation"]]],
            ],
            "required": ["language", "corrected", "issues"],
        ]
        let system = """
            You check a text the user wrote (often a translation into a language they're learning) for spelling, grammar \
            (agreement, conjugation, articles, prepositions) and unnatural wording. For each problem give the exact \
            erroneous passage as it appears in the text (short — a word or a few words), the correction, the kind, and a \
            one-line explanation in \(explainIn). Don't flag what is correct. Also give the language (English name) and the \
            whole corrected text, changing nothing else.
            """
        let reply = try await StructuredCompletion.json(Reply.self, provider: provider, model: model, system: system, user: text, schema: schema, maxTokens: 1_500)
        let corrected = reply.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsText = text as NSString
        func span(_ issue: SpellingIssue) -> NSRange { NSRange(location: issue.location, length: (issue.text as NSString).length) }

        // The model's issues, placed only where they match whole words (so "a" never lands inside "allé").
        var modelIssues: [SpellingIssue] = []
        for issue in reply.issues {
            let snippet = issue.text.trimmingCharacters(in: .whitespaces)
            guard !snippet.isEmpty, snippet != issue.correction else { continue }
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: snippet) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length))
            else { continue }  // invented or rephrased: not shown
            modelIssues.append(SpellingIssue(
                location: match.range.location, text: snippet, correction: issue.correction,
                kind: SpellingIssue.Kind(rawValue: issue.kind) ?? .grammar, explanation: issue.explanation
            ))
        }

        // Where: spell-checker hits (certain), then every change in the corrected text (exact and complete),
        // then model issues nothing else covers (style remarks without a change). Explanations come from the model.
        var issues = spelling
        for change in changes(from: text, to: corrected) where !issues.contains(where: { NSIntersectionRange(span($0), span(change)).length > 0 }) {
            issues.append(change)
        }
        for index in issues.indices {
            let overlapping = modelIssues.filter { NSIntersectionRange(span($0), span(issues[index])).length > 0 }
            if issues[index].explanation.isEmpty, let first = overlapping.first {
                issues[index].explanation = overlapping.map(\.explanation).filter { !$0.isEmpty }.joined(separator: " ")
                if issues[index].kind == .grammar { issues[index].kind = first.kind }
            }
        }
        for issue in modelIssues where !issues.contains(where: { NSIntersectionRange(span($0), span(issue)).length > 0 }) {
            issues.append(issue)
        }
        issues.sort { $0.location < $1.location }
        return SpellingResult(text: text, language: reply.language, issues: issues, corrected: corrected.isEmpty ? text : corrected)
    }
}

extension SpellingChecker {
    /// Word-level differences between a text and its corrected version (longest common subsequence).
    static func changes(from original: String, to corrected: String) -> [SpellingIssue] {
        func words(_ text: String) -> [(word: String, location: Int)] {
            let ns = text as NSString
            var result: [(String, Int)] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
                result.append((ns.substring(with: range), range.location))
            }
            return result
        }
        let a = words(original), b = words(corrected)
        guard !a.isEmpty, !b.isEmpty, a.count < 2_000, b.count < 2_000 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i].word == b[j].word ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var issues: [SpellingIssue] = []
        var i = 0, j = 0
        let ns = original as NSString
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i].word == b[j].word {
                i += 1; j += 1
                continue
            }
            // A run of changes: original words i..<i2 became corrected words j..<j2.
            var i2 = i, j2 = j
            while i2 < a.count || j2 < b.count {
                if i2 < a.count, j2 < b.count, a[i2].word == b[j2].word { break }
                if j2 >= b.count || (i2 < a.count && table[i2 + 1][j2] >= table[i2][j2 + 1]) { i2 += 1 } else { j2 += 1 }
            }
            if i2 > i {
                let start = a[i].location
                let end = a[i2 - 1].location + (a[i2 - 1].word as NSString).length
                let replacement = b[j..<j2].map(\.word).joined(separator: " ")
                issues.append(SpellingIssue(
                    location: start, text: ns.substring(with: NSRange(location: start, length: end - start)),
                    correction: replacement, kind: .grammar, explanation: ""
                ))
            }
            i = i2; j = j2
        }
        return issues
    }
}

/// A /learn session's progress (stored with the message, so it survives leaving the conversation).
public struct LearnSession: Codable, Sendable, Hashable {
    public var cardIDs: [UUID]
    public var position: Int
    public var grades: [UUID: ReviewGrade]

    public init(cardIDs: [UUID]) {
        self.cardIDs = cardIDs
        position = 0
        grades = [:]
    }

    public var isFinished: Bool { position >= cardIDs.count }
}

/// Language names as typed ("Französisch", "fr", "español") → the English name cards use.
public enum LanguageName {
    static let names: [String: String] = [
        "french": "French", "französisch": "French", "francais": "French", "français": "French", "fr": "French",
        "spanish": "Spanish", "spanisch": "Spanish", "español": "Spanish", "espanol": "Spanish", "es": "Spanish",
        "english": "English", "englisch": "English", "en": "English",
        "german": "German", "deutsch": "German", "de": "German",
        "italian": "Italian", "italienisch": "Italian", "italiano": "Italian", "it": "Italian",
        "portuguese": "Portuguese", "portugiesisch": "Portuguese", "português": "Portuguese", "pt": "Portuguese",
        "dutch": "Dutch", "niederländisch": "Dutch", "nl": "Dutch",
        "breton": "Breton", "bretonisch": "Breton", "br": "Breton",
        "japanese": "Japanese", "japanisch": "Japanese", "ja": "Japanese",
    ]

    public static func normalized(_ text: String) -> String? {
        names[text.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    /// "Hund Spanish" → ("Hund", "Spanish"); "boulangerie" → ("boulangerie", nil).
    public static func split(_ arguments: String) -> (text: String, language: String?) {
        var words = arguments.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1, let last = words.last.flatMap(normalized) {
            words.removeLast()
            if words.last?.lowercased() == "in" { words.removeLast() }
            return (words.joined(separator: " "), last)
        }
        return (arguments.trimmingCharacters(in: .whitespaces), nil)
    }
}
