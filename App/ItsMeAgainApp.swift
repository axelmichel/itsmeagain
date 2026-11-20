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
                .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        }
        .modelContainer(for: CompanionSchema.models)
        .commands {
            // The main window owns ⌘N ("New Chat"); there is only one window.
            CommandGroup(replacing: .newItem) {}
            TaskCommands(app: app)
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
