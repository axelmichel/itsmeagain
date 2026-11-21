import AppKit
import Learning
import Persistence
import SwiftData
import SwiftUI

/// Your text with the errors highlighted (red spelling, orange grammar, yellow style), the list of
/// corrections, and the corrected text to copy.
struct SpellingView: View {
    let result: SpellingResult

    private func color(_ kind: SpellingIssue.Kind) -> Color {
        switch kind {
        case .spelling: .red
        case .grammar: .orange
        case .style: .yellow
        }
    }

    private var highlighted: AttributedString {
        var text = AttributedString(result.text)
        let ns = result.text as NSString
        for issue in result.issues {
            let range = NSRange(location: issue.location, length: (issue.text as NSString).length)
            guard range.location + range.length <= ns.length, let swiftRange = Range(range, in: result.text),
                let lower = AttributedString.Index(swiftRange.lowerBound, within: text),
                let upper = AttributedString.Index(swiftRange.upperBound, within: text)
            else { continue }
            text[lower..<upper].backgroundColor = color(issue.kind).opacity(0.28)
            text[lower..<upper].underlineStyle = .single
            text[lower..<upper].underlineColor = NSColor(color(issue.kind))
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(highlighted)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field)
            if !result.issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.issues) { issue in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(color(issue.kind)).frame(width: 7, height: 7)
                            Text(issue.text).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            Text(issue.correction.isEmpty ? "?" : issue.correction).fontWeight(.medium)
                            if !issue.explanation.isEmpty {
                                Text(issue.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Corrected").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.corrected, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    Text(result.corrected).textSelection(.enabled)
                }
                .padding(10)
                .background(Theme.field)
            }
            HStack(spacing: 12) {
                legend("spelling", .red)
                legend("grammar", .orange)
                legend("style", .yellow)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
    }
}

/// A flashcard: front, click to flip.
struct FlashcardView: View {
    let card: Flashcard
    @State private var flipped = false

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { flipped.toggle() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(card.language).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    Spacer()
                    Text(flipped ? "back" : "front · click to flip").font(.caption2).foregroundStyle(.tertiary)
                }
                if flipped {
                    Text(card.back).font(.title3.weight(.medium))
                    if !card.partOfSpeech.isEmpty { Text(card.partOfSpeech).font(.caption).foregroundStyle(.secondary) }
                    if !card.example.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.example).italic()
                            Text(card.exampleTranslation).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !card.notes.isEmpty { Text(card.notes).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text(card.front).font(.title2.weight(.semibold))
                }
            }
            .padding(14)
            .frame(maxWidth: 420, minHeight: 110, alignment: .topLeading)
            .background(Theme.field)
            .overlay(Rectangle().stroke(Theme.border))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A /learn session: the card's front, Show, then Again / Hard / Good / Easy; a summary at the end.
struct LearnSessionView: View {
    let message: StoredMessage
    let index: Int
    let session: LearnSession
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.isFinished {
                summary
            } else if let card = app.learning.card(session.cardIDs[session.position]) {
                HStack {
                    Text("Card \(session.position + 1) of \(session.cardIDs.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if card.isNew { Text("new").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent) }
                    Text(card.language).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.front).font(.title2.weight(.semibold))
                    if revealed {
                        Divider()
                        Text(card.back).font(.title3.weight(.medium))
                        if !card.partOfSpeech.isEmpty { Text(card.partOfSpeech).font(.caption).foregroundStyle(.secondary) }
                        if !card.example.isEmpty {
                            Text(card.example).italic()
                            Text(card.exampleTranslation).font(.callout).foregroundStyle(.secondary)
                        }
                        if !card.notes.isEmpty { Text(card.notes).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding(14)
                .frame(maxWidth: 460, minHeight: 100, alignment: .topLeading)
                .background(Theme.field)
                .overlay(Rectangle().stroke(Theme.border))
                if revealed {
                    HStack(spacing: 8) {
                        ForEach(ReviewGrade.allCases, id: \.self) { grade in
                            Button(grade.title) { answer(card.id, grade) }
                        }
                    }
                } else {
                    // No plain-key shortcuts: they would fire while typing in the message field.
                    Button("Show Answer") { revealed = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                // The card was deleted meanwhile.
                Button("Skip (card deleted)") { advance(nil, nil) }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var summary: some View {
        let counts = Dictionary(grouping: session.grades.values, by: { $0 }).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Done — \(session.cardIDs.count) cards").font(.headline)
            Text(ReviewGrade.allCases.compactMap { grade in counts[grade].map { "\(grade.title) \($0)" } }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            let due = app.learning.deck.dueCount()
            Text(due > 0 ? "\(due) cards are due again soon — /learn when you like." : "Nothing else is due today.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func answer(_ id: UUID, _ grade: ReviewGrade) {
        app.learning.grade(id, grade)
        advance(id, grade)
    }

    private func advance(_ id: UUID?, _ grade: ReviewGrade?) {
        var attachments = message.attachments
        guard attachments.indices.contains(index), case .learnSession(var stored) = attachments[index] else { return }
        if let id, let grade { stored.grades[id] = grade }
        stored.position += 1
        attachments[index] = .learnSession(stored)
        message.attachments = attachments
        try? context.save()
        revealed = false
    }
}
