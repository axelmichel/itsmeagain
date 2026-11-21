import AppKit
import Foundation
import Learning
import NaturalLanguage
import Observation

/// Vocabulary cards (Flashcards.json) and the text check's macOS spell-checker part.
@MainActor
@Observable
final class LearningModel {
    private(set) var deck = FlashcardDeck()
    @ObservationIgnored private let store = FlashcardFileStore(url: AppData.flashcards)

    /// The language cards and explanations are written in (default: the system language).
    var explainIn: String = UserDefaults.standard.string(forKey: "learningExplainIn")
        ?? Locale(identifier: "en").localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English" {
        didSet { UserDefaults.standard.set(explainIn, forKey: "learningExplainIn") }
    }

    func load() async {
        deck = await store.load()
    }

    private func save() {
        let snapshot = deck
        Task { try? await store.save(snapshot) }
    }

    @discardableResult
    func add(_ card: Flashcard) -> (card: Flashcard, isNew: Bool) {
        let result = deck.add(card)
        save()
        return result
    }

    func grade(_ id: UUID, _ grade: ReviewGrade) {
        deck.grade(id, grade)
        save()
    }

    func remove(_ id: UUID) {
        deck.remove(id)
        save()
    }

    func card(_ id: UUID) -> Flashcard? { deck.cards.first { $0.id == id } }

    /// macOS's own spell checker (offline, many languages): misspelled words with its first guess.
    func systemSpellingIssues(_ text: String) -> (issues: [SpellingIssue], language: String?) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let code = recognizer.dominantLanguage?.rawValue
        let checker = NSSpellChecker.shared
        let language = code.flatMap { code in checker.availableLanguages.first { $0 == code || $0.hasPrefix(code + "_") } }
        guard let language else { return ([], code) }
        var issues: [SpellingIssue] = []
        let ns = text as NSString
        var start = 0
        while start < ns.length {
            let range = checker.checkSpelling(of: text, startingAt: start, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            let word = ns.substring(with: range)
            let guess = checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0)?.first ?? ""
            issues.append(SpellingIssue(location: range.location, text: word, correction: guess, kind: .spelling, explanation: ""))
            start = range.location + range.length
        }
        return (issues, code)
    }
}
