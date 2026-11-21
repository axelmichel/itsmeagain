import Commands
import Foundation
import Learning
import Persistence
import SwiftData

/// /spelling <text>, /flashcard <word> [language], /learn [number] [language] — local model only.
extension AppModel {
    func runLearningCommand(_ handler: String, input: CommandInput, text: String, in conversation: Conversation, context: ModelContext) -> CommandOutcome {
        let argument = input.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        switch handler {
        case "spelling" where argument.isEmpty: return .failed("Usage: /spelling <your text> (several lines are fine)")
        case "flashcard" where argument.isEmpty: return .failed("Usage: /flashcard <word> [language], e.g. /flashcard boulangerie or /flashcard Hund Spanish")
        default: break
        }
        if handler == "learn", learning.deck.cards.isEmpty { return .failed("No cards yet. Make some with /flashcard <word>.") }
        guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
        let model = try? localMailModel()
        if handler != "learn", model == nil { return .failed("This needs a local Chat model (Settings → Tasks → Chat).") }

        if conversation.messages.isEmpty { conversation.title = handler == "learn" ? "Learning" : text }
        conversation.append(role: .user, content: text, task: conversation.task)
        let reply = conversation.append(role: .assistant, content: "", task: conversation.task)
        try? context.save()
        let learning = learning

        switch handler {
        case "spelling":
            reply.content = "_Checking…_"
            chat.run(in: conversation, context: context) {
                let system = learning.systemSpellingIssues(argument)
                do {
                    let result = try await SpellingChecker.check(
                        argument, spelling: system.issues, explainIn: learning.explainIn, provider: model!.provider, model: model!.model)
                    reply.content = result.issues.isEmpty ? "No errors found (\(result.language))." : "**\(result.issues.count) \(result.issues.count == 1 ? "thing" : "things")** to fix (\(result.language)):"
                    reply.attachments = [.spelling(result)]
                } catch {
                    reply.content = ""
                    reply.errorText = error.localizedDescription
                }
            }
        case "flashcard":
            reply.content = "_Making the card…_"
            let (word, language) = LanguageName.split(argument)
            chat.run(in: conversation, context: context) {
                do {
                    let card = try await FlashcardMaker.make(word, language: language, explainIn: learning.explainIn, provider: model!.provider, model: model!.model)
                    let (stored, isNew) = learning.add(card)
                    let count = learning.deck.cards.filter { $0.language == stored.language }.count
                    reply.content = (isNew ? "Added" : "Updated") + " to your \(stored.language) cards (\(count) now). Learn them with /learn."
                    reply.attachments = [.flashcards([stored])]
                } catch {
                    reply.content = ""
                    reply.errorText = error.localizedDescription
                }
            }
        default:  // learn
            var limit = 10
            var language: String?
            for part in input.positional {
                if let number = Int(part) { limit = min(max(number, 1), 100) } else if let name = LanguageName.normalized(part) ?? learning.deck.languages.first(where: { $0.localizedCaseInsensitiveCompare(part) == .orderedSame }) { language = name }
            }
            let cards = learning.deck.session(limit: limit, language: language)
            if cards.isEmpty {
                reply.content = "No \(language.map { "\($0) " } ?? "")cards to learn right now."
            } else {
                let due = cards.filter { !$0.isNew }.count
                reply.content = "**\(cards.count) cards**\(language.map { " · \($0)" } ?? "") — \(due) due, \(cards.count - due) new."
                reply.attachments = [.learnSession(LearnSession(cardIDs: cards.map(\.id)))]
            }
            try? context.save()
        }
        return .handled
    }
}
