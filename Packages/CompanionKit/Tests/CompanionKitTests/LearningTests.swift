import CompanionCore
import Foundation
import Testing

@testable import Learning

@Suite struct FlashcardTests {
    let now = Date(timeIntervalSince1970: 1_795_600_000)

    @Test func sameWordUpdatesAndKeepsSchedule() {
        var deck = FlashcardDeck()
        let first = deck.add(Flashcard(language: "French", front: "la boulangerie", back: "Bäckerei", created: now))
        deck.grade(first.card.id, .good, now: now)
        let again = deck.add(Flashcard(language: "French", front: "La Boulangerie", back: "Bäckerei, Brotladen", created: now))
        #expect(!again.isNew && deck.cards.count == 1)
        #expect(deck.cards[0].back == "Bäckerei, Brotladen" && deck.cards[0].reviews == 1)
        #expect(deck.add(Flashcard(language: "Spanish", front: "la boulangerie", back: "x")).isNew, "other language: its own card")
    }

    @Test func schedulingGrowsAndResets() {
        var card = Flashcard(language: "French", front: "le chat", back: "Katze", created: now)
        card = FlashcardDeck.schedule(card, .good, now: now)
        #expect(card.interval == 1 && card.due == now.addingTimeInterval(86_400))
        card = FlashcardDeck.schedule(card, .good, now: now)
        #expect(card.interval == 3)
        card = FlashcardDeck.schedule(card, .good, now: now)
        #expect(card.interval == 7.5, "3 × ease 2.5")
        card = FlashcardDeck.schedule(card, .again, now: now)
        #expect(card.interval == 0 && card.lapses == 1 && card.due == now.addingTimeInterval(600) && card.ease < 2.5)
        let easy = FlashcardDeck.schedule(Flashcard(language: "F", front: "x", back: "y", created: now), .easy, now: now)
        #expect(easy.interval == 4 && easy.ease > 2.5)
    }

    @Test func sessionsTakeDueFirstThenNew() {
        var deck = FlashcardDeck()
        let old = deck.add(Flashcard(language: "French", front: "un", back: "eins", created: now.addingTimeInterval(-100))).card
        deck.add(Flashcard(language: "French", front: "deux", back: "zwei", created: now.addingTimeInterval(-50)))
        deck.add(Flashcard(language: "Spanish", front: "uno", back: "eins", created: now))
        deck.grade(old.id, .good, now: now.addingTimeInterval(-2 * 86_400))  // due a day ago
        #expect(deck.session(limit: 10, language: "french", now: now).map(\.front) == ["un", "deux"])
        #expect(deck.session(limit: 1, now: now).map(\.front) == ["un"])
        #expect(deck.languages == ["French", "Spanish"])
    }

    @Test func wordDiffFindsUnlistedChanges() {
        let changes = SpellingChecker.changes(
            from: "Les croissant était délicieux et le pain aussi.", to: "Les croissants étaient délicieux et le pain aussi.")
        #expect(changes.map(\.text) == ["croissant était"])
        #expect(changes.first?.correction == "croissants étaient")
        #expect(SpellingChecker.changes(from: "Tout va bien.", to: "Tout va bien.").isEmpty)
    }

    @Test func makerAndChecker() async throws {
        let card = try await FlashcardMaker.make(
            "boulangerie", language: nil, explainIn: "German",
            provider: ScriptedProvider(reply: #"{"language":"french","word":"la boulangerie","translation":"die Bäckerei","part_of_speech":"Nomen (f)","example":"Je vais à la boulangerie.","example_translation":"Ich gehe zur Bäckerei.","notes":""}"#),
            model: "m")
        #expect(card.language == "French" && card.front == "la boulangerie" && card.back == "die Bäckerei")

        let text = "Je suis allé a la boulangerie hier, elle était fermé. Les croissant était bon."
        let reply = #"{"language":"French","corrected":"Je suis allé à la boulangerie hier, elle était fermée. Les croissants étaient bons.","issues":[{"text":"a","correction":"à","kind":"spelling","explanation":"Präposition à"},{"text":"fermé","correction":"fermée","kind":"grammar","explanation":"Angleichung an elle"},{"text":"invented words","correction":"x","kind":"style","explanation":"?"}]}"#
        let result = try await SpellingChecker.check(text, spelling: [], explainIn: "German", provider: ScriptedProvider(reply: reply), model: "m")
        let nsText = text as NSString
        #expect(result.issues.map(\.text) == ["a", "fermé", "croissant était bon"], "every change from the corrected text; 'a' as a whole word")
        #expect(result.issues[0].location == nsText.range(of: " a ").location + 1)
        #expect(result.issues[0].explanation == "Präposition à" && result.issues[0].kind == .spelling)
        #expect(result.issues[1].explanation == "Angleichung an elle")
        #expect(result.corrected.hasSuffix("étaient bons."))
    }
}

/// `OLLAMA_LIVE=1 swift test --filter LearningLiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OLLAMA_LIVE"] == "1"))
struct LearningLiveTests {
    @Test func cardsAndSpelling() async throws {
        let provider = OllamaProviderForTests.make()
        for (word, language) in [("boulangerie", nil), ("Hund", "Spanish")] as [(String, String?)] {
            let started = ContinuousClock.now
            let card = try await FlashcardMaker.make(word, language: language, explainIn: "German", provider: provider, model: "gemma4:26b")
            print("LEARN LIVE: \(word) → [\(card.language)] \(card.front) = \(card.back) (\(card.partOfSpeech)) · \(card.example) / \(card.exampleTranslation) · \(card.notes) — \(ContinuousClock.now - started)")
        }
        let text = "Hier je suis allé a la boulangerie, mais elle était fermé. Les croissant était délicieux."
        let started = ContinuousClock.now
        let result = try await SpellingChecker.check(text, spelling: [], explainIn: "German", provider: provider, model: "gemma4:26b")
        print("LEARN LIVE: spelling (\(result.language)) in \(ContinuousClock.now - started)")
        for issue in result.issues { print("  [\(issue.kind.rawValue)] \(issue.text) → \(issue.correction): \(issue.explanation)") }
        print("  corrected: \(result.corrected)")
        #expect(result.issues.count >= 3)
    }
}

@Suite struct LanguageNameTests {
    @Test func splitsTheLanguageOff() {
        #expect(LanguageName.split("Hund Spanish") == ("Hund", "Spanish"))
        #expect(LanguageName.split("le petit déjeuner in Französisch") == ("le petit déjeuner", "French"))
        #expect(LanguageName.split("boulangerie") == ("boulangerie", nil))
        #expect(LanguageName.split("French") == ("French", nil), "a single word is the word, not the language")
    }
}
