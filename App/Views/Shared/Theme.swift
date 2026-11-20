import AppKit
import ObjectiveC
import SwiftUI

/// Flat zones like Zed (One Dark greys in dark mode): lighter header bars, neutral grey selection and a
/// soft blue accent. The logo's raspberry/coral colours are reserved for the logo and icon.
enum Theme {
    /// Title bar row and the area around the message editor.
    static let header = Color(light: 0xE8E8EA, dark: 0x343943)
    /// Conversation list.
    static let sidebar = Color(light: 0xF0F0F2, dark: 0x2A2E36)
    /// Transcript.
    static let canvas = Color(light: 0xFAFAFB, dark: 0x2C3038)
    /// The message field, inset into the header-coloured composer area.
    static let field = Color(light: 0xFFFFFF, dark: 0x2A2E36)
    /// Selected rows, user messages, queued messages.
    static let selection = Color(light: 0xDCDDE1, dark: 0x3D414B)
    static let hover = Color(light: 0xE6E7EA, dark: 0x33373F)
    /// Code blocks: recessed into the transcript.
    static let recessed = Color(light: 0xF0F1F3, dark: 0x24272C)
    /// Lines between zones (darker than the zones in dark mode, like Zed).
    static let border = Color(light: 0xD4D5D9, dark: 0x1F2228)
    /// Zed's One Dark blue; also the app accent (Assets → AccentColor).
    static let accent = Color(light: 0x3B6FD8, dark: 0x74ADE8)
}

extension Color {
    /// sRGB hex colours that switch with the window's appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Thin, auto-hiding overlay scrollbars everywhere in the app, even when macOS is set to always show
/// (thick, legacy) scrollbars: every NSScrollView asks `NSScroller.preferredScrollerStyle`, so answering
/// `.overlay` there covers SwiftUI's scroll views, lists and text editors alike.
enum OverlayScrollers {
    static func enable() {
        guard let method = class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)) else {
            return
        }
        let overlay: @convention(block) (AnyObject) -> Int = { _ in NSScroller.Style.overlay.rawValue }
        method_setImplementation(method, imp_implementationWithBlock(overlay))
    }
}
