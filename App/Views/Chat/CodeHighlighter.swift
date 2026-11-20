import AppKit
import Highlighter
import SwiftUI

/// Syntax highlighting for code blocks via highlight.js (HighlighterSwift), using the Atom One themes
/// to match the One Dark look. Only colours are taken; font and background come from the code block.
@MainActor
final class CodeHighlighter {
    static let shared = CodeHighlighter()

    /// Larger blocks stay plain; highlighting is synchronous on the main thread.
    private static let maxLength = 40_000

    private let dark: Highlighter?
    private let light: Highlighter?
    private let cache = NSCache<NSString, CachedHighlight>()

    private init() {
        dark = Highlighter()
        _ = dark?.setTheme("atom-one-dark")
        light = Highlighter()
        _ = light?.setTheme("atom-one-light")
        cache.countLimit = 300
    }

    func highlight(_ code: String, language: String?, dark isDark: Bool) -> AttributedString? {
        guard !code.isEmpty, code.count <= Self.maxLength, let highlighter = isDark ? dark : light else { return nil }
        let language = language?.lowercased()
        let key = "\(isDark ? 1 : 0)|\(language ?? "")|\(code)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }

        // Unknown fence languages fall back to highlight.js auto-detection.
        guard let highlighted = language.flatMap({ highlighter.highlight(code, as: $0) }) ?? highlighter.highlight(code) else {
            return nil
        }
        var result = AttributedString(code)
        let full = NSRange(location: 0, length: highlighted.length)
        highlighted.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor,
                let stringRange = Range(range, in: highlighted.string),
                highlighted.string == code,
                let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                let upper = AttributedString.Index(stringRange.upperBound, within: result)
            else { return }
            result[lower..<upper].foregroundColor = Color(nsColor: color)
        }
        cache.setObject(CachedHighlight(result), forKey: key)
        return result
    }
}

private final class CachedHighlight {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}
