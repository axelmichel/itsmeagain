import Persistence
import SwiftData
import SwiftUI

@main
struct ItsMeAgainApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("ItsMeAgain", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 720, minHeight: 480)
        }
        .modelContainer(for: CompanionSchema.models)
        .commands {
            // The main window owns ⌘N ("New Chat"); there is only one window.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
