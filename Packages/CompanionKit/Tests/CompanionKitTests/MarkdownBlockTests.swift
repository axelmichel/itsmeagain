import CompanionCore
import Testing

@Suite struct MarkdownBlockTests {
    @Test func splitsProseAndCode() {
        let markdown = """
            Here you go:

            ```swift
            let x = 1

            print(x)
            ```
            Done.
            """
        #expect(MarkdownBlock.parse(markdown) == [
            .text("Here you go:"),
            .code(language: "swift", code: "let x = 1\n\nprint(x)"),
            .text("Done."),
        ])
    }

    @Test func unclosedFenceIsCode() {
        #expect(MarkdownBlock.parse("Intro\n```\nfoo(") == [.text("Intro"), .code(language: nil, code: "foo(")])
    }

    @Test func longerFenceMustBeClosedByMatchingMarker() {
        let markdown = "````md\n```\ninner\n```\n````"
        #expect(MarkdownBlock.parse(markdown) == [.code(language: "md", code: "```\ninner\n```")])
    }

    @Test func plainText() {
        #expect(MarkdownBlock.parse("a\n\nb") == [.text("a\n\nb")])
        #expect(MarkdownBlock.parse("") == [])
    }

    @Test func headingsAndRules() {
        let markdown = "# Title\nIntro\n## Part 2 ##\n---\n#hashtag stays text\n```\n# not a heading\n```"
        #expect(MarkdownBlock.parse(markdown) == [
            .heading(level: 1, text: "Title"),
            .text("Intro"),
            .heading(level: 2, text: "Part 2"),
            .rule,
            .text("#hashtag stays text"),
            .code(language: nil, code: "# not a heading"),
        ])
    }
}
