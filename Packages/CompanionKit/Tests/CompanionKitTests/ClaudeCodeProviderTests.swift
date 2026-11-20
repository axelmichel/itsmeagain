import CompanionCore
import Foundation
import Testing

@testable import Providers

@Suite struct ClaudeCodeProviderTests {
    /// A stand-in `claude`: records its arguments and stdin, then prints canned stream-json.
    func fakeCLI(output: [String], exitCode: Int = 0, stderr: String = "") throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appending(path: "claude")
        let jsonl = dir.appending(path: "out.jsonl")
        try output.joined(separator: "\n").write(to: jsonl, atomically: true, encoding: .utf8)
        try """
            #!/bin/sh
            printf '%s\\n' "$@" > "\(dir.path)/args.txt"
            cat > "\(dir.path)/stdin.txt"
            pwd > "\(dir.path)/cwd.txt"
            cat "\(jsonl.path)"
            printf '%s' '\(stderr)' >&2
            exit \(exitCode)
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, dir)
    }

    @Test func streamsTextAndPassesSafeArguments() async throws {
        let (cli, dir) = try fakeCLI(output: [
            #"{"type":"system","subtype":"init","model":"claude-haiku-5-5","tools":[]}"#,
            #"{"type":"stream_event","event":{"type":"message_start","message":{"usage":{"input_tokens":5}}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}}"#,
            #"{"type":"rate_limit_event"}"#,
            #"{"type":"stream_event","event":{"type":"message_stop"}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Hello","usage":{"input_tokens":5,"output_tokens":2}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let workdir = dir.appending(path: "work")
        let provider = ClaudeCodeProvider(id: ProviderID("claude-code"), displayName: "Claude Code", executable: cli, workingDirectory: workdir)

        let events = try await provider.stream(ChatRequest(
            model: "haiku",
            system: "Be brief.",
            messages: [.user("Hi"), .assistant("Hello!"), .user("Again")],
            options: ChatOptions(think: false)
        )).collect()

        #expect(events == [.textDelta("Hel"), .textDelta("lo"), .done(Usage(promptTokens: 5, completionTokens: 2))])
        let arguments = try String(contentsOf: dir.appending(path: "args.txt"), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(arguments.starts(with: ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--model", "haiku"]))
        #expect(arguments.contains("--system-prompt") && arguments.contains("Be brief."))
        #expect(arguments.contains("--effort"))
        #expect(!arguments.contains("--bare"), "bare mode ignores the subscription login")
        let stdin = try String(contentsOf: dir.appending(path: "stdin.txt"), encoding: .utf8)
        #expect(stdin == "Conversation so far:\n\nUser: Hi\n\nAssistant: Hello!\n\nReply to the user's latest message:\n\nAgain")
        let cwd = try String(contentsOf: dir.appending(path: "cwd.txt"), encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(cwd.hasSuffix("/work"))
    }

    @Test func reportsErrorResultsAndCrashes() async throws {
        let (cli, dir) = try fakeCLI(output: [#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Not logged in · Please run /login"}"#])
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ClaudeCodeProvider(id: ProviderID("c"), displayName: "C", executable: cli, workingDirectory: dir)
        await #expect(throws: ProviderError.server("Claude Code: Not logged in · Please run /login")) {
            _ = try await provider.stream(ChatRequest(model: "haiku", messages: [.user("x")])).collect()
        }

        let (crash, dir2) = try fakeCLI(output: [], exitCode: 3, stderr: "boom")
        defer { try? FileManager.default.removeItem(at: dir2) }
        let crashing = ClaudeCodeProvider(id: ProviderID("c"), displayName: "C", executable: crash, workingDirectory: dir2)
        await #expect(throws: ProviderError.server("Claude Code exited (3): boom")) {
            _ = try await crashing.stream(ChatRequest(model: "haiku", messages: [.user("x")])).collect()
        }
    }

    @Test func missingExecutable() async throws {
        let provider = ClaudeCodeProvider(id: ProviderID("c"), displayName: "C", executable: nil, workingDirectory: FileManager.default.temporaryDirectory)
        await #expect(throws: ProviderError.self) { _ = try await provider.listModels() }
        #expect(ClaudeCodeProvider.locate(custom: "/definitely/not/here") == ClaudeCodeProvider.locate())
    }
}

/// Runs the real `claude` CLI on the user's subscription. `CLAUDE_CODE_LIVE=1 swift test --filter ClaudeCodeLiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_CODE_LIVE"] == "1"))
struct ClaudeCodeLiveTests {
    @Test func answersWithSystemPromptAndHistory() async throws {
        let workdir = FileManager.default.temporaryDirectory.appending(path: "claude-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workdir) }
        let provider = ClaudeCodeProvider(id: ProviderID("claude-code"), displayName: "Claude Code", executable: ClaudeCodeProvider.locate(), workingDirectory: workdir)
        let events = try await provider.stream(ChatRequest(
            model: "haiku",
            system: "Answer with a single word, lowercase.",
            messages: [.user("My favourite colour is teal."), .assistant("Noted."), .user("What is my favourite colour?")]
        )).collect()
        let text = events.compactMap { if case .textDelta(let delta) = $0 { delta } else { nil } }.joined()
        print("CLAUDE CODE:", text)
        #expect(text.lowercased().contains("teal"))
        #expect(events.last.map { if case .done = $0 { true } else { false } } == true)
    }
}
