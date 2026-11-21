import Commands
import Foundation
import Observation

/// Built-in commands plus the user's Markdown commands from `Application Support/ItsMeAgain/Commands`,
/// reloaded automatically when files in that folder change.
@MainActor
@Observable
final class CommandCenter {
    static let builtIns = CommandRegistry.general + CommandRegistry.calendar + CommandRegistry.mail + CommandRegistry.memory
    private(set) var registry = CommandRegistry(builtIns: CommandCenter.builtIns)
    private(set) var fileErrors: [CommandLibrary.FileError] = []
    let directory = AppData.directory.appending(path: "Commands", directoryHint: .isDirectory)
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
        watch()
    }

    func reload() {
        let (commands, errors) = CommandLibrary.load(from: directory)
        registry = CommandRegistry(builtIns: Self.builtIns, user: commands)
        fileErrors = errors
    }

    /// Creates a commented template file and returns it (the caller opens it in an editor).
    func createCommandFile() -> URL {
        var url = directory.appending(path: "my-command.md")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = directory.appending(path: "my-command-\(number).md")
            number += 1
        }
        let template = """
            ---
            description: What this command does (shown in the / list)
            argument-hint: <text>
            task: chat                     # chat (default), translate, research or code
            # tools: search_documents      # optional: limit which tools it may use
            # auto-approve:                # optional: write tools that run without asking
            # aliases: mc                  # optional: other names
            ---
            Write the prompt here. Placeholders: $ARGUMENTS (everything after the name), $1 $2 …,
            {{today}}, {{now}}, {{date}}, {{date:-1d}}, {{date:+1w}}.

            Example: Summarise the following in three bullet points: $ARGUMENTS
            """
        try? template.write(to: url, atomically: true, encoding: .utf8)
        reload()
        return url
    }

    /// Folder-level file events (create, delete, rename, atomic saves) trigger a debounced reload.
    private func watch() {
        let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend, .attrib], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reload()
        }
    }
}
