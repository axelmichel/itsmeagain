import CompanionCore
import Foundation

/// Runs the user's installed, unmodified Claude Code CLI (`claude -p`), which signs in with the user's own
/// subscription. The app never sees credentials; Claude Code's tools, settings, hooks and MCP servers are
/// turned off so it behaves as a plain chat model. Each turn starts a fresh, non-persisted session and
/// receives the transcript as its prompt.
public struct ClaudeCodeProvider: LLMProvider {
    public let id: ProviderID
    public let displayName: String
    public let executable: URL?
    /// An empty directory, so no project CLAUDE.md or settings are picked up.
    public let workingDirectory: URL
    public var capabilities: ProviderCapabilities { [.streaming, .thinking] }

    public init(id: ProviderID, displayName: String, executable: URL?, workingDirectory: URL) {
        self.id = id
        self.displayName = displayName
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    /// GUI apps don't inherit the shell's PATH, so look in the usual install locations.
    public static func locate(custom: String? = nil) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        var candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home).local/bin/claude", "\(home).claude/local/claude"]
        if let custom = custom?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            candidates.insert((custom as NSString).expandingTildeInPath, at: 0)
        }
        return candidates.map { URL(filePath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    public func listModels() async throws -> [ModelInfo] {
        guard executable != nil else { throw Self.notFound }
        return [
            ModelInfo(id: "opus", displayName: "Claude Opus (latest)"),
            ModelInfo(id: "sonnet", displayName: "Claude Sonnet (latest)"),
            ModelInfo(id: "haiku", displayName: "Claude Haiku (latest)"),
        ]
    }

    static let notFound = ProviderError.unavailable("Claude Code isn't installed (or not found). Install it and run `claude` once in Terminal to sign in.")

    func arguments(for request: ChatRequest) -> [String] {
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "",
            "--model", request.model,
        ]
        if let system = request.system, !system.isEmpty { arguments += ["--system-prompt", system] }
        if request.options.think == false { arguments += ["--effort", "low"] }
        return arguments
    }

    /// Earlier turns go into the prompt; Claude's context is large, so nothing is dropped.
    static func prompt(for messages: [ChatMessage]) -> String {
        let turns = messages.filter { ($0.role == .user || $0.role == .assistant) && !$0.content.isEmpty }
        guard turns.count > 1 else { return turns.last?.content ?? "" }
        let transcript = turns.dropLast().map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }
        return "Conversation so far:\n\n\(transcript.joined(separator: "\n\n"))\n\nReply to the user's latest message:\n\n\(turns.last!.content)"
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = ProcessBox()
            let process = box.process
            let task = Task {
                do {
                    guard let executable else { throw Self.notFound }
                    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
                    process.executableURL = executable
                    process.arguments = arguments(for: request)
                    process.currentDirectoryURL = workingDirectory
                    var environment = ProcessInfo.processInfo.environment
                    let path = environment["PATH"] ?? "/usr/bin:/bin"
                    environment["PATH"] = "\(executable.deletingLastPathComponent().path(percentEncoded: false)):/opt/homebrew/bin:/usr/local/bin:\(path)"
                    process.environment = environment

                    let input = Pipe(), output = Pipe(), errors = Pipe()
                    process.standardInput = input
                    process.standardOutput = output
                    process.standardError = errors
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf: Data(Self.prompt(for: request.messages).utf8))
                    try input.fileHandleForWriting.close()

                    var parser = AnthropicProvider.StreamParser()
                    var finished = false
                    for try await line in output.fileHandleForReading.bytes.lines where !line.isEmpty {
                        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                        switch message["type"]?.stringValue {
                        case "stream_event":
                            guard let event = message["event"] else { continue }
                            for chatEvent in try parser.consume(event.jsonString) {
                                switch chatEvent {
                                case .textDelta, .thinkingDelta: continuation.yield(chatEvent)
                                default: break  // no tools; usage is reported with the result
                                }
                            }
                        case "result":
                            finished = true
                            if message["is_error"] == true {
                                let detail = message["result"]?.stringValue ?? message["subtype"]?.stringValue ?? "unknown error"
                                throw ProviderError.server("Claude Code: \(detail)")
                            }
                            continuation.yield(.done(Usage(
                                promptTokens: message["usage"]?["input_tokens"]?.intValue,
                                completionTokens: message["usage"]?["output_tokens"]?.intValue
                            )))
                        default:
                            break  // system/init, rate limit notices, full assistant messages
                        }
                    }
                    process.waitUntilExit()
                    if !finished {
                        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw ProviderError.server(
                            "Claude Code exited (\(process.terminationStatus))" + (stderr.isEmpty ? "." : ": \(stderr.suffix(400))")
                        )
                    }
                    continuation.finish()
                } catch {
                    if process.isRunning { process.terminate() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if box.process.isRunning { box.process.terminate() }
            }
        }
    }
}

/// `Process` isn't Sendable, but `isRunning`/`terminate()` are safe to call from any thread.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
}
