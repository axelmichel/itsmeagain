import AppKit
import SwiftUI

/// Menu bar icon: the logo's two interlocking peaks as a template image, so macOS tints it.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            path.lineWidth = 2.2
            path.lineJoinStyle = .miter
            path.lineCapStyle = .butt
            // Outer peak.
            path.move(to: NSPoint(x: 1, y: 1))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 1))
            path.line(to: NSPoint(x: rect.maxX - 1, y: 1))
            // Inner valley.
            path.move(to: NSPoint(x: 4.6, y: 7.2))
            path.line(to: NSPoint(x: rect.midX, y: 1.5))
            path.line(to: NSPoint(x: rect.maxX - 4.6, y: 7.2))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image)
            // The label exists for the app's lifetime, so its openWindow can reopen a closed main window.
            .onAppear { app.openWindowAction = openWindow }
    }
}

struct MenuBarMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Quick Ask" + (app.quickPanelShortcut.map { "  \($0.displayString)" } ?? "")) {
            app.quickPanel?.show()
        }
        Button("Open ItsMeAgain") { app.openMainWindow() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit ItsMeAgain") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
