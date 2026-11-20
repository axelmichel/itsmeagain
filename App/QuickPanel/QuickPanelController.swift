import AppKit
import SwiftData
import SwiftUI

/// Spotlight-style floating panel: takes keyboard input without activating the app, closes on Escape or
/// when it loses focus, and grows downward as the answer streams in.
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    private let app: AppModel
    private let container: ModelContainer
    private var panel: QuickPanel?
    let state = QuickPanelState()

    init(app: AppModel, container: ModelContainer) {
        self.app = app
        self.container = container
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        state.prepareForShowing(app: app)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        state.focusRequest += 1
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickPanel {
        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.backgroundColor = .clear

        let root = QuickPanelView(state: state, onClose: { [weak self] in self?.close() })
            .environment(app)
            .modelContainer(container)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        return panel
    }

    /// Upper third of the screen with the mouse, like Spotlight.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let top = visible.maxY - visible.height * 0.22
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: top - size.height))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking elsewhere dismisses the panel; a running reply keeps streaming in the background.
        close()
    }
}

/// Becomes key (so the text field works) without activating the app, and keeps its top edge fixed
/// when the SwiftUI content changes height.
final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, frameRect.size.height != frame.size.height, frameRect.origin.y == frame.origin.y {
            rect.origin.y = frame.maxY - frameRect.height
        }
        super.setFrame(rect, display: flag)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
