import Foundation
import Testing

@testable import Commands
@testable import Routing

@Suite struct CommandInputTests {
    @Test func parsesNameArgumentsAndQuotes() throws {
        let input = try #require(CommandInput(#"/Remind "call mum" tomorrow 9am"#))
        #expect(input.name == "remind")
        #expect(input.arguments == #""call mum" tomorrow 9am"#)
        #expect(input.positional == ["call mum", "tomorrow", "9am"])
    }

    @Test(arguments: ["hello", "/ space", "/", "//x", "/a.b", " not /cmd"])
    func rejectsNonCommands(text: String) {
        #expect(CommandInput(text) == nil)
    }

    @Test func emptyArgumentsAndEmptyQuotes() throws {
        #expect(try #require(CommandInput("/today")).positional == [])
        #expect(try #require(CommandInput(#"/x "" b"#)).positional == ["", "b"])
    }
}

@Suite struct TemplateExpanderTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    // Saturday, 21 November 2026, 10:30 in Berlin.
    let now = Date(timeIntervalSince1970: 1_795_253_400)

    @Test func expandsArgumentsAndDates() throws {
        let input = try #require(CommandInput(#"/standup "API work" extra"#))
        let template = "Focus: $ARGUMENTS | first: $1 | second: $2 | third: '$3' | yesterday {{date:-1d}} | next week {{date:+1w}} | month {{date:+1m}} | today {{date}}"
        let result = TemplateExpander.expand(template, input: input, now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
        #expect(result == #"Focus: "API work" extra | first: API work | second: extra | third: '' | yesterday 2026-11-20 | next week 2026-11-28 | month 2026-12-21 | today 2026-11-21"#)
    }

    @Test func longDates() throws {
        let input = try #require(CommandInput("/x"))
        let result = TemplateExpander.expand("{{today}}", input: input, now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))
        #expect(result == "Saturday, 21 November 2026")
    }
}

@Suite struct CommandFileTests {
    @Test func parsesFrontmatterAndTemplate() throws {
        let text = """
            ---
            description: "Draft my stand-up"   # shown in the list
            argument-hint: [focus]
            tools: [calendar_events, search_notes]
            auto-approve: create_reminder
            aliases: su, standup2
            ---
            Notes from {{date:-1d}}. Focus: $ARGUMENTS
            """
        let spec = try CommandFile.parse(text, fileName: "Standup", path: "/c/Standup.md")
        #expect(spec.name == "standup")
        #expect(spec.summary == "Draft my stand-up")
        #expect(spec.argumentHint == "[focus]")
        #expect(spec.scope == .personal, "chat commands are personal by default")
        #expect(spec.aliases == ["su", "standup2"])
        #expect(spec.source == .user(path: "/c/Standup.md"))
        #expect(spec.kind == .prompt(PromptCommand(
            template: "Notes from {{date:-1d}}. Focus: $ARGUMENTS",
            task: .chat,
            tools: ["calendar_events", "search_notes"],
            autoApproved: ["create_reminder"]
        )))
    }

    @Test func codeCommandsAreGeneralAndHashInValueIsKept() throws {
        let spec = try CommandFile.parse("---\ndescription: Post to #general\ntask: code\n---\nReview $ARGUMENTS", fileName: "review", path: "/r.md")
        #expect(spec.scope == .general)
        #expect(spec.summary == "Post to #general")
    }

    @Test(arguments: [
        ("---\ndescription: x\n", "Frontmatter is not closed with ---"),
        ("---\ndescription: x\n---\n", "The command has no prompt text"),
        ("---\ntask: x\n---\nhi", "Missing “description”"),
        ("---\ndescription: d\ntask: poetry\n---\nhi", "Unknown task “poetry” (chat, translate, research, code)"),
        ("---\ndescription: d\njust text\n---\nhi", "Expected “key: value” but found “just text”"),
    ])
    func reportsErrors(text: String, message: String) {
        #expect(throws: CommandFile.ParseError(message: message)) {
            try CommandFile.parse(text, fileName: "x", path: "/x.md")
        }
    }

    @Test func libraryLoadsGoodFilesAndReportsBadOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "---\ndescription: Good\n---\nHi".write(to: dir.appending(path: "good.md"), atomically: true, encoding: .utf8)
        try "no frontmatter and no description".write(to: dir.appending(path: "bad.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let (commands, errors) = CommandLibrary.load(from: dir)
        #expect(commands.map(\.name) == ["good"])
        #expect(errors.map(\.message) == ["Missing “description”"])
    }
}

@Suite struct CommandRegistryTests {
    let user = CommandSpec(name: "standup", summary: "s", kind: .prompt(PromptCommand(template: "t")), scope: .personal, source: .user(path: "/s.md"), aliases: ["su"])

    @Test func completesByPrefixThenContains() {
        let registry = CommandRegistry(builtIns: CommandRegistry.general, user: [user])
        #expect(registry.completions(for: "/").count == 5)
        #expect(registry.completions(for: "/s").map(\.name) == ["standup", "task"], "prefix match first, then contains")
        #expect(registry.completions(for: "/ew").map(\.name) == ["new"], "contains-match as fallback")
        #expect(registry.completions(for: "/su").map(\.name) == ["standup"], "aliases complete too")
        #expect(registry.completions(for: "/new chat").isEmpty, "no list once arguments start")
        #expect(registry.completions(for: "hello").isEmpty)
    }

    @Test func resolvesAliasesAndGuardsBuiltIns() {
        let clash = CommandSpec(name: "help", summary: "mine", kind: .prompt(PromptCommand(template: "t")), scope: .general, source: .user(path: "/h.md"))
        let registry = CommandRegistry(builtIns: CommandRegistry.general, user: [user, clash])
        #expect(registry.command(named: "SU")?.name == "standup")
        #expect(registry.command(named: "help")?.source == .builtIn)
        #expect(registry.conflicts.count == 1)

        var override = clash
        override.overridesBuiltIn = true
        #expect(CommandRegistry(builtIns: CommandRegistry.general, user: [override]).command(named: "help")?.summary == "mine")
    }
}
