import Foundation

/// A video from the playlist, with whether the vault already has it.
public struct PlaylistVideo: Codable, Sendable, Hashable, Identifiable {
    public var position: Int
    public var videoID: String
    public var title: String
    /// The note that already has this video (vault-relative), if any.
    public var existingNote: String?
    /// Set once a note was created (or creating failed) in this card.
    public var createdNote: String?
    public var failure: String?

    public var id: String { videoID }
    public var isNew: Bool { existingNote == nil }
    public var url: String { "https://www.youtube.com/watch?v=\(videoID)" }
}

/// Runs the vault's own scripts: `.claude/skills/yt-playlist/playlist.py` and the `yt2obsidian.py`
/// tool (the same ones the Claude skills use), so behaviour stays identical.
public enum YouTubeImport {
    public static let defaultTool = URL.homeDirectory.appending(path: "development/private/tools/yt2obsidian.py")
    public static let defaultPython = URL.homeDirectory.appending(path: "development/private/tools/.venv/bin/python")
    /// The skill's own limit: YouTube blocks transcript requests after about 15 in a row.
    public static let batchLimit = 15

    /// The playlist id from `_recherche-quellen.md` ("YouTube-Playlist" section).
    public static func playlistID(_ store: NoteStore) -> String? {
        guard let text = try? String(contentsOf: try store.resolve("_recherche-quellen.md"), encoding: .utf8) else { return nil }
        let section = text.range(of: "YouTube-Playlist").map { text[$0.upperBound...] } ?? Substring(text)
        return section.firstMatch(of: /`(PL[\w-]{8,})`/).map { String($0.output.1) }
    }

    /// Lists the playlist with the skill's script (reads the playlist page; marks videos already in the vault).
    public static func playlist(_ store: NoteStore, id: String) async throws -> [PlaylistVideo] {
        let script = try store.resolveTool(".claude/skills/yt-playlist/playlist.py")
        let output = try await run(
            URL(filePath: "/usr/bin/python3"), ["-I", script.path, id, store.vault.root.path], in: store.vault.root, timeout: 90
        )
        return parsePlaylist(output.stdout)
    }

    static func parsePlaylist(_ text: String) -> [PlaylistVideo] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, let position = Int(fields[0]), fields[2].count == 11 else { return nil }
            let note = fields.count > 4 ? fields[4].trimmingCharacters(in: .whitespaces) : ""
            return PlaylistVideo(
                position: position, videoID: fields[2], title: fields[3],
                existingNote: fields[1] == "SEEN" ? (note.isEmpty ? "already in the vault" : note) : nil
            )
        }
    }

    public enum Event: Sendable, Equatable {
        case progress(String)
        case saved(url: String?, path: String)
        case failed(url: String, reason: String)
        case finished(code: Int32)
    }

    /// Runs `yt2obsidian.py` for the URLs (one Ollama start for all, like the skill says). Streams events;
    /// the tool handles the URLs in order, so the n-th result belongs to the n-th URL.
    public static func createNotes(
        urls: [String], python: URL = defaultPython, tool: URL = defaultTool
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = python
            // -u: unbuffered output (with -I, the PYTHONUNBUFFERED variable would be ignored).
            process.arguments = ["-I", "-u", tool.path] + urls
            // One pipe for both: "Saved:" goes to stdout, "FAILED" to stderr, and only a shared channel
            // keeps them in the order the tool wrote them (results are matched to URLs by that order).
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let parser = ToolOutputParser(urls: urls, continuation: continuation)
            let finished = DispatchSemaphore(value: 0)
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    parser.feed("\n")
                    finished.signal()
                } else {
                    parser.feed(String(decoding: data, as: UTF8.self))
                }
            }
            process.terminationHandler = { process in
                // Let the last output drain before reporting the end.
                _ = finished.wait(timeout: .now() + 2)
                continuation.yield(.finished(code: process.terminationStatus))
                continuation.finish()
            }
            continuation.onTermination = { _ in if process.isRunning { process.terminate() } }
            do {
                try process.run()
            } catch {
                continuation.yield(.failed(url: urls.first ?? "", reason: "Couldn't start the yt tool: \(error.localizedDescription)"))
                continuation.yield(.finished(code: -1))
                continuation.finish()
            }
        }
    }

    struct Output: Sendable {
        var stdout: String
        var stderr: String
        var code: Int32
    }

    static func run(_ executable: URL, _ arguments: [String], in directory: URL, timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
            DispatchQueue.global().async {
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus != 0 && stdout.isEmpty {
                    continuation.resume(throwing: VaultError.invalid(stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "The playlist script failed (exit \(process.terminationStatus))." : stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    continuation.resume(returning: Output(stdout: stdout, stderr: stderr, code: process.terminationStatus))
                }
            }
        }
    }
}

extension NoteStore {
    /// A tool file inside the vault's `.claude/` folder (normally skipped for notes).
    func resolveTool(_ relative: String) throws -> URL {
        guard relative.hasPrefix(".claude/"), !relative.contains("..") else { throw VaultError.outsideVault(relative) }
        let url = vault.root.appending(path: relative).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw VaultError.notFound(relative) }
        return url
    }
}

/// Turns the tool's output (spinner lines end in \r, results in \n) into events.
final class ToolOutputParser: @unchecked Sendable {
    private let lock = NSLock()
    private let urls: [String]
    private var done = 0
    private var buffer = ""
    private let continuation: AsyncStream<YouTubeImport.Event>.Continuation

    init(urls: [String], continuation: AsyncStream<YouTubeImport.Event>.Continuation) {
        self.urls = urls
        self.continuation = continuation
    }

    func feed(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += text
        var lines = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        buffer = lines.removeLast()
        for raw in lines { handle(raw.trimmingCharacters(in: .whitespaces)) }
    }

    private func handle(_ line: String) {
        guard !line.isEmpty else { return }
        // A spinner line without a final \r can run into the result on the same line: search, don't anchor.
        if let saved = line.range(of: "Saved:") {
            let url = done < urls.count ? urls[done] : nil
            done += 1
            continuation.yield(.saved(url: url, path: line[saved.upperBound...].trimmingCharacters(in: .whitespaces)))
        } else if let failed = line.range(of: "FAILED ") {
            let rest = line[failed.upperBound...]
            let separator = rest.range(of: ": ")
            let url = separator.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            let reason = separator.map { String(rest[$0.upperBound...]) } ?? "failed"
            done += 1
            continuation.yield(.failed(url: url, reason: reason))
        } else if line.hasSuffix("characters)") {
            continuation.yield(.progress(line))
        } else if let range = line.range(of: #"(Fetching|Summarizing|Merging)[^–]*"#, options: .regularExpression) {
            continuation.yield(.progress("\(min(done + 1, urls.count))/\(urls.count): " + line[range].trimmingCharacters(in: .whitespaces)))
        }
    }
}
