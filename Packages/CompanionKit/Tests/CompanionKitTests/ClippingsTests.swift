import CompanionCore
import Foundation
import Testing

@testable import Obsidian
import Providers

@Suite struct ClippingsTests {
    static let claudeMD = """
        # CLAUDE.md
        ## Ordnerstruktur
        | Ordner | Zweck | Regel |
        | `Clippings/` | Inbox | x |
        | `second-brain/` | Themen: `Agentic Coding/`, `Local LLMs/`, `Frontend & Web/` | y |
        ## Tags
        - `ai/`: `agentic-coding`, `local-llm`
        - `web/`: `frontend`
        - lose: `youtube`, `ollama`
        ## Verlinkung
        - `ignored`: `no`
        """

    @Test func readsConventionsFromClaudeMD() {
        let conventions = VaultConventions.parse(Self.claudeMD, existing: ["second-brain/Rust", "second-brain/Local LLMs", "Projects"])
        #expect(conventions.topicFolders == ["second-brain/Agentic Coding", "second-brain/Local LLMs", "second-brain/Frontend & Web", "second-brain/Rust"])
        #expect(conventions.tags == ["ai/agentic-coding", "ai/local-llm", "web/frontend", "youtube", "ollama"])
    }

    @Test func frontmatterEditing() {
        var frontmatter = Frontmatter("title: \"Gemma 4 locally\"\nurl: https://www.youtube.com/watch?v=abcdefghijk\ndate: 2026-11-21\ntags:\n  - youtube\n  - llm-stuff")
        #expect(frontmatter.value("title") == "Gemma 4 locally")
        #expect(frontmatter.tags == ["youtube", "llm-stuff"])
        frontmatter.set("blurb", "Runs \"Gemma 4\" on a Mac.", after: ["date"])
        frontmatter.setTags(["youtube", "ai/local-llm"])
        #expect(frontmatter.text == "title: \"Gemma 4 locally\"\nurl: https://www.youtube.com/watch?v=abcdefghijk\ndate: 2026-11-21\nblurb: \"Runs \\\"Gemma 4\\\" on a Mac.\"\ntags:\n  - youtube\n  - ai/local-llm")
    }

    @Test func relatedBlockAddsOnlyMissingLinks() {
        let body = "\n# Title\nText"
        let first = RelatedBlock.ensure([RelatedLink(note: "A", reason: "same topic")], in: body)
        #expect(first == "> [!info]- Related\n> Up: [[Home]]\n> - [[A]] — same topic\n\n# Title\nText")
        let second = RelatedBlock.ensure([RelatedLink(note: "A", reason: "x"), RelatedLink(note: "B", reason: "also")], in: first)
        #expect(second == "> [!info]- Related\n> Up: [[Home]]\n> - [[A]] — same topic\n> - [[B]] — also\n\n# Title\nText")
    }

    @Test func folderRulesFromTheSkillWin() {
        let folders = ["second-brain/Agentic Coding", "second-brain/Local LLMs", "second-brain/Frontend & Web"]
        #expect(ClippingSorter.folder(for: ["youtube", "ollama"], available: folders) == "second-brain/Local LLMs")
        #expect(ClippingSorter.folder(for: ["ai/mcp", "web/frontend"], available: folders) == "second-brain/Agentic Coding", "checked in the skill's order")
        #expect(ClippingSorter.folder(for: ["dev/rust"], available: folders) == nil)
    }

    @Test func movesOnlyFromClippingsIntoSecondBrainAndNeverOverwrites() throws {
        let vault = try FixtureVault(files: [
            "Clippings/New.md": "x", "Clippings/Dup.md": "y", "second-brain/Local LLMs/Dup.md": "existing", "Projects/P.md": "p",
        ])
        defer { vault.remove() }
        #expect(try vault.store.moveClipping("Clippings/New.md", to: "second-brain/Local LLMs") == "second-brain/Local LLMs/New.md")
        #expect(throws: VaultError.self) { try vault.store.moveClipping("Clippings/Dup.md", to: "second-brain/Local LLMs") }
        #expect(vault.text("second-brain/Local LLMs/Dup.md") == "existing" && vault.text("Clippings/Dup.md") == "y")
        #expect(throws: VaultError.self) { try vault.store.moveClipping("Projects/P.md", to: "second-brain/Local LLMs") }
        #expect(throws: VaultError.self) { try vault.store.moveClipping("Clippings/Dup.md", to: "Projects") }
        #expect(throws: VaultError.self) { try vault.store.moveClipping("Clippings/Dup.md", to: "second-brain/Missing") }
    }

    @Test func applyWritesFrontmatterRelatedMoveAndBacklinks() throws {
        let vault = try FixtureVault(files: [
            "Clippings/Gemma locally.md": "---\ntitle: \"Gemma locally\"\nurl: https://www.youtube.com/watch?v=abcdefghijk\ndate: 2026-11-21\ntags:\n  - youtube\n  - free-tag\n---\n\n# Gemma locally\n\n## Summary\n- runs fast\n",
            "second-brain/Local LLMs/Ollama tuning.md": "---\ntitle: Ollama tuning\n---\n# Ollama tuning\n",
        ])
        defer { vault.remove() }
        let proposal = SortProposal(
            path: "Clippings/Gemma locally.md", title: "Gemma locally", url: "https://www.youtube.com/watch?v=abcdefghijk",
            folder: "second-brain/Local LLMs", tags: ["youtube", "ai/local-llm"], blurb: "Gemma 4 running on a Mac with Ollama.",
            blurbIsNew: true, related: [RelatedLink(note: "Ollama tuning", reason: "Same local inference setup.")], duplicates: [], status: .pending
        )
        let moved = try ClippingSorter.apply(proposal, store: vault.store)
        #expect(moved == "second-brain/Local LLMs/Gemma locally.md" && vault.text("Clippings/Gemma locally.md") == nil)
        let note = try #require(vault.text(moved))
        #expect(note.contains("date: 2026-11-21\nblurb: \"Gemma 4 running on a Mac with Ollama.\"\ntags:\n  - youtube\n  - ai/local-llm\n---\n"))
        #expect(note.contains("---\n> [!info]- Related\n> Up: [[Home]]\n> - [[Ollama tuning]] — Same local inference setup.\n\n# Gemma locally"))
        #expect(vault.text("second-brain/Local LLMs/Ollama tuning.md")?.contains("> - [[Gemma locally]] — Gemma 4 running on a Mac with Ollama.") == true)

        var duplicate = proposal
        duplicate.duplicates = ["second-brain/x.md"]
        #expect(throws: VaultError.self) { try ClippingSorter.apply(duplicate, store: vault.store) }
    }

    @Test func parsesPlaylistOutput() {
        let output = "1\tNEW\tabcdefghijk\tFirst video\t\n2\tSEEN\tbcdefghijkl\tSecond\tsecond-brain/Local LLMs/Second.md\nwarning line\n"
        let videos = YouTubeImport.parsePlaylist(output)
        #expect(videos.map(\.videoID) == ["abcdefghijk", "bcdefghijkl"])
        #expect(videos[0].isNew && videos[1].existingNote == "second-brain/Local LLMs/Second.md")
        #expect(videos[0].url == "https://www.youtube.com/watch?v=abcdefghijk")
    }

    @Test func playlistIDFromSourcesNote() throws {
        let vault = try FixtureVault(files: ["_recherche-quellen.md": "## Other\n`PLnotthisone1234`\n## YouTube-Playlist\n- Playlist \"Techstuff\": `PLRIQ4S7WsG00`\n"])
        defer { vault.remove() }
        #expect(YouTubeImport.playlistID(vault.store) == "PLRIQ4S7WsG00")
    }

    @Test func runnerMapsResultsToURLsInOrder() async throws {
        let tool = FileManager.default.temporaryDirectory.appending(path: "fake-yt-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: tool) }
        try """
            import sys
            for u in sys.argv[1:]:
                sys.stderr.write("\\r⠋ Fetching transcript\\r⠙ Summarizing with gemma4:26b – 12 tokens")
                if "bad" in u:
                    print(f"FAILED {u}: no transcript", file=sys.stderr)
                else:
                    print("  A title (1,234 characters)", file=sys.stderr)
                    print("Saved: Clippings/" + u[-3:] + ".md")
            """.write(to: tool, atomically: true, encoding: .utf8)
        var events: [YouTubeImport.Event] = []
        for await event in YouTubeImport.createNotes(urls: ["https://y/abc", "https://y/bad", "https://y/xyz"], python: URL(filePath: "/usr/bin/python3"), tool: tool) {
            events.append(event)
        }
        #expect(events.contains(.saved(url: "https://y/abc", path: "Clippings/abc.md")))
        #expect(events.contains(.failed(url: "https://y/bad", reason: "no transcript")))
        #expect(events.contains(.saved(url: "https://y/xyz", path: "Clippings/xyz.md")))
        #expect(events.last == .finished(code: 0))
    }
}

/// Real vault, read-only: playlist listing and a sorting *plan* (nothing applied). `VAULT_LIVE=1 swift test --filter ClippingsLiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VAULT_LIVE"] == "1"))
struct ClippingsLiveTests {
    @Test func playlistAndPlan() async throws {
        let vault = try #require(Vault.detect().first { $0.name == "bits-and-bytes" })
        let store = NoteStore(vault: vault)
        let conventions = VaultConventions.read(store)
        print("CLIP LIVE: \(conventions.topicFolders.count) topic folders, \(conventions.tags.count) tags from CLAUDE.md")
        let id = try #require(YouTubeImport.playlistID(store))
        var started = ContinuousClock.now
        let videos = try await YouTubeImport.playlist(store, id: id)
        print("CLIP LIVE: playlist \(id): \(videos.count) videos, \(videos.filter(\.isNew).count) new, in \(ContinuousClock.now - started)")
        let clippings = store.clippings()
        print("CLIP LIVE: \(clippings.count) notes in Clippings/")
        started = ContinuousClock.now
        let proposals = await ClippingSorter.plan(
            store: store, paths: Array(clippings.prefix(4)), conventions: conventions, semantic: nil,
            provider: OllamaProvider(), model: "gemma4:26b")
        print("CLIP LIVE: planned \(proposals.count) in \(ContinuousClock.now - started) (without related links)")
        for proposal in proposals {
            print("  \(proposal.title.prefix(60)) → \(proposal.folder ?? "unsure") · \(proposal.tags.joined(separator: ", ")) · dup \(proposal.duplicates.count)\n    blurb\(proposal.blurbIsNew ? " (new)" : ""): \(proposal.blurb)")
        }
        #expect(!conventions.topicFolders.isEmpty && !conventions.tags.isEmpty)
    }
}

@Suite struct NewTopicFolderTests {
    @Test func namesAreMadeSafe() {
        #expect(NoteStore.topicFolderName("Swift") == "Swift")
        #expect(NoteStore.topicFolderName("second-brain/Home Lab") == "Home Lab")
        #expect(NoteStore.topicFolderName("AI: Agents/MCP") == "AI- Agents-MCP")
        #expect(NoteStore.topicFolderName("..") == nil)
        #expect(NoteStore.topicFolderName("  ") == nil)
    }

    @Test func createsOnlyDirectlyUnderSecondBrainAndOnApply() throws {
        let vault = try FixtureVault(files: [
            "Clippings/Swift Testing.md": "---\ntitle: Swift Testing\n---\n# Swift Testing\n", "second-brain/Rust/R.md": "r",
        ])
        defer { vault.remove() }
        #expect(throws: VaultError.self) { try vault.store.createTopicFolder("Projects/New") }
        #expect(throws: VaultError.self) { try vault.store.createTopicFolder("second-brain/A/B") }
        try vault.store.createTopicFolder("second-brain/Rust")  // existing is fine

        let proposal = SortProposal(
            path: "Clippings/Swift Testing.md", title: "Swift Testing", url: nil, folder: "second-brain/Swift", newFolder: true,
            tags: [], blurb: "", blurbIsNew: false, related: [], duplicates: [], status: .pending
        )
        #expect(!FileManager.default.fileExists(atPath: vault.root.appending(path: "second-brain/Swift").path), "nothing before Apply")
        let moved = try ClippingSorter.apply(proposal, store: vault.store)
        #expect(moved == "second-brain/Swift/Swift Testing.md" && vault.text(moved) != nil)
    }

    @Test func oldPlansStillDecode() throws {
        let json = #"{"path":"Clippings/a.md","title":"a","tags":[],"blurb":"","blurbIsNew":false,"related":[],"duplicates":[],"status":"pending"}"#
        let proposal = try JSONDecoder().decode(SortProposal.self, from: Data(json.utf8))
        #expect(proposal.newFolder == nil && proposal.folder == nil)
    }
}
