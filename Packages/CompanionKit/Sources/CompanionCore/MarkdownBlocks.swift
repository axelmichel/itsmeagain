import Foundation

/// Splits model output into prose and fenced code blocks, so the UI can render code separately.
/// Tolerates an unclosed fence (common mid-stream) by treating the rest as code.
public enum MarkdownBlock: Sendable, Hashable {
    case text(String)
    case code(language: String?, code: String)

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var buffer: [Substring] = []
        var fence: (marker: String, language: String?)?

        func flush() {
            let joined = buffer.joined(separator: "\n")
            buffer.removeAll()
            if let fence {
                blocks.append(.code(language: fence.language, code: joined))
            } else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(joined.trimmingCharacters(in: .newlines)))
            }
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open.marker), trimmed.drop(while: { $0 == open.marker.first }).isEmpty {
                    flush()
                    fence = nil
                } else {
                    buffer.append(line)
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let character = trimmed.first!
                let marker = String(trimmed.prefix(while: { $0 == character }))
                let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                fence = (marker, info.isEmpty ? nil : String(info.split(separator: " ").first!))
            } else {
                buffer.append(line)
            }
        }
        flush()
        return blocks
    }
}
