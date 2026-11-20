import AppKit
import SwiftUI

/// Flat zones in grades of grey (Zed-style), adapting to light and dark mode.
enum Theme {
    /// Conversation list.
    static let sidebar = Color(light: 0.925, dark: 0.105)
    /// Transcript.
    static let canvas = Color(light: 0.985, dark: 0.135)
    /// Area around the editor: queue, task bar.
    static let panel = Color(light: 0.950, dark: 0.165)
    /// The message field itself.
    static let field = Color(light: 1.000, dark: 0.200)
    /// User bubbles, queued messages.
    static let raised = Color(light: 0.915, dark: 0.215)
    /// Code blocks: recessed into the transcript.
    static let recessed = Color(light: 0.945, dark: 0.100)
    static let border = Color(light: 0.850, dark: 0.250)
}

extension Color {
    /// A grey that switches with the window's appearance.
    init(light: Double, dark: Double) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}
