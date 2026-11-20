import AppKit
import SwiftUI

/// Click, then press a key combination with ⌘, ⌥ or ⌃. Escape cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: HotKeyShortcut?
    let onRecordingChange: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press shortcut…" : shortcut?.displayString ?? "None")
                    .monospaced()
                    .frame(minWidth: 110)
            }
            if shortcut != nil && !recording {
                Button("Clear", systemImage: "xmark.circle.fill") { shortcut = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Escape
                stop()
            } else if let new = HotKeyShortcut(event: event) {
                shortcut = new
                stop()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        onRecordingChange(false)
    }
}
