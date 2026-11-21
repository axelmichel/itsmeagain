import Foundation
import Routing

/// User commands are Markdown files with a small frontmatter (the same keys Claude Code uses for its
/// custom commands, plus a few of our own):
///
/// ```markdown
/// ---
/// description: Draft my stand-up from yesterday's notes and today's calendar   # " # " starts a comment
/// argument-hint: [focus]
/// task: chat                      # chat (default), translate, research, code
/// tools: calendar_events, search_notes
/// auto-approve: create_reminder
/// scope: personal                 # personal (default for chat) or general
/// aliases: su
/// override: false                 # true to replace a built-in command of the same name
/// ---
/// Using my notes from {{date:-1d}} and today's calendar, draft a short stand-up. Focus: $ARGUMENTS
/// ```
///
/// The command name is the file name without `.md` (or `name:`).
public enum CommandFile {
    public struct ParseError: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ text: String, fileName: String, path: String) throws -> CommandSpec {
        var lines = text.components(separatedBy: .newlines)
        var fields: [String: String] = [:]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines.removeFirst()
            guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
                throw ParseError(message: "Frontmatter is not closed with ---")
            }
            for line in lines[..<end] {
                // " # " starts a comment; "#general" (no space after #) stays part of the value.
                let content = line.range(of: " # ").map { String(line[..<$0.lowerBound]) } ?? line
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                guard let colon = content.firstIndex(of: ":") else {
                    throw ParseError(message: "Expected “key: value” but found “\(line.trimmingCharacters(in: .whitespaces))”")
                }
                let key = content[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = unquote(content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            lines.removeFirst(end + 1)
        }
        let template = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { throw ParseError(message: "The command has no prompt text") }

        let name = (fields["name"] ?? fileName).lowercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw ParseError(message: "Invalid command name “\(name)” (letters, digits, - and _ only)")
        }
        guard let summary = fields["description"] ?? fields["summary"], !summary.isEmpty else {
            throw ParseError(message: "Missing “description”")
        }
        var task = TaskKind.chat
        if let raw = fields["task"] {
            guard let parsed = TaskKind(rawValue: raw.lowercased()) else {
                throw ParseError(message: "Unknown task “\(raw)” (chat, translate, research, code)")
            }
            task = parsed
        }
        var scope: CommandSpec.Scope = task == .chat ? .personal : .general
        if let raw = fields["scope"] {
            guard let parsed = CommandSpec.Scope(rawValue: raw.lowercased()) else {
                throw ParseError(message: "Unknown scope “\(raw)” (personal, general)")
            }
            scope = parsed
        }
        return CommandSpec(
            name: name,
            summary: summary,
            argumentHint: fields["argument-hint"].flatMap { $0.isEmpty ? nil : $0 },
            kind: .prompt(PromptCommand(
                template: template,
                task: task,
                tools: fields["tools"].map(list),
                autoApproved: Set(fields["auto-approve"].map(list) ?? [])
            )),
            scope: scope,
            source: .user(path: path),
            aliases: fields["aliases"].map(list)?.map { $0.lowercased() } ?? [],
            overridesBuiltIn: ["true", "yes"].contains(fields["override"]?.lowercased())
        )
    }

    /// `a, b` or `[a, b]`.
    static func list(_ value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// Loads every `*.md` in a folder; broken files are reported, not fatal.
public enum CommandLibrary {
    public struct FileError: Sendable, Hashable, Identifiable {
        public var path: String
        public var message: String
        public var id: String { path }
    }

    public static func load(from directory: URL) -> (commands: [CommandSpec], errors: [FileError]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var commands: [CommandSpec] = []
        var errors: [FileError] = []
        for file in files.filter({ $0.pathExtension.lowercased() == "md" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let path = file.path(percentEncoded: false)
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                commands.append(try CommandFile.parse(text, fileName: file.deletingPathExtension().lastPathComponent, path: path))
            } catch {
                errors.append(FileError(path: path, message: error.localizedDescription))
            }
        }
        return (commands, errors)
    }
}
