import Persistence
import SwiftData
import SwiftUI

@main
struct ItsMeAgainApp: App {
    @State private var app: AppModel
    private let container: ModelContainer

    init() {
        // Must run before settings are read and the store is opened.
        AppData.migrateFromSandboxContainer()
        _app = State(initialValue: AppModel())
        do {
            container = try ModelContainer(
                for: Schema(CompanionSchema.models),
                configurations: ModelConfiguration(url: AppData.store)
            )
        } catch {
            fatalError("Couldn't open the conversation store at \(AppData.store.path): \(error)")
        }
    }

    var body: some Scene {
        Window("ItsMeAgain", id: "main") {
            ContentView()
                .environment(app)
                .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        }
        .modelContainer(container)
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
