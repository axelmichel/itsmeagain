import Foundation

/// Splits text into overlapping passages, preferring paragraph, then line, sentence and word boundaries.
public enum Chunker {
    public struct Chunk: Equatable, Sendable {
        /// Character offset of the passage in the original text.
        public var offset: Int
        public var text: String
    }

    public static func chunks(_ text: String, size: Int = 1_500, overlap: Int = 200) -> [Chunk] {
        precondition(size > overlap && overlap >= 0)
        let characters = Array(text)
        var result: [Chunk] = []
        var start = 0
        while start < characters.count {
            var end = min(start + size, characters.count)
            if end < characters.count {
                end = breakPoint(in: characters, from: start + size / 2, to: end) ?? end
            }
            let passage = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !passage.isEmpty {
                result.append(Chunk(offset: start, text: passage))
            }
            guard end < characters.count else { break }
            // Step back for overlap, then forward to the next word so passages don't start mid-word.
            var next = max(end - overlap, start + 1)
            while next < end, !characters[next - 1].isWhitespace { next += 1 }
            start = next
        }
        return result
    }

    /// The latest good boundary in `lower..<upper` (index just after it), best kind first.
    private static func breakPoint(in characters: [Character], from lower: Int, to upper: Int) -> Int? {
        let isParagraph: (Int) -> Bool = { $0 > 0 && characters[$0] == "\n" && characters[$0 - 1] == "\n" }
        let isLine: (Int) -> Bool = { characters[$0] == "\n" }
        let isSentence: (Int) -> Bool = { i in
            ".!?".contains(characters[i]) && i + 1 < characters.count && characters[i + 1].isWhitespace
        }
        let isSpace: (Int) -> Bool = { characters[$0].isWhitespace }
        for test in [isParagraph, isLine, isSentence, isSpace] {
            if let index = (lower..<upper).last(where: test) { return index + 1 }
        }
        return nil
    }
}
