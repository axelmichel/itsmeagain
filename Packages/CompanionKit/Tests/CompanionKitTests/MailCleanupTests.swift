import CompanionCore
import Foundation
import Synchronization
import Testing

@testable import Mail
@testable import Providers

@Suite struct MIMEParserTests {
    @Test func multipartWithQuotedPrintableAndBase64() {
        let raw = """
            From: "Weekly AI" <news@ai.example>
            Subject: =?utf-8?Q?Gr=C3=BC=C3=9Fe_aus_der?= =?utf-8?B?IEtJLVdlbHQ=?=
            List-Unsubscribe: <mailto:leave@ai.example>, <https://ai.example/unsub?u=1>
            List-Unsubscribe-Post: List-Unsubscribe=One-Click
            Content-Type: multipart/alternative; boundary="b1"

            --b1
            Content-Type: text/plain; charset=utf-8
            Content-Transfer-Encoding: quoted-printable

            Neue Modelle f=C3=BCr lokale KI =
            und mehr.
            --b1
            Content-Type: text/html; charset=utf-8
            Content-Transfer-Encoding: base64

            \(Data("<html><body><h1>Issue 42</h1><p>Qwen 4 is out: <a href=\"https://x.example/qwen\">read more</a></p><style>p{}</style></body></html>".utf8).base64EncodedString())
            --b1--
            """
        let mail = MIMEParser.parse(raw)
        #expect(mail.headers["subject"] == "Grüße aus der KI-Welt")
        #expect(mail.plainText == "Neue Modelle für lokale KI und mehr.")
        #expect(mail.readableText == "Issue 42\nQwen 4 is out: read more (https://x.example/qwen)")

        let bulk = BulkInfo.from(headers: mail.headers)
        #expect(bulk == BulkInfo(isBulk: true, unsubscribeURL: "https://ai.example/unsub?u=1", oneClick: true, unsubscribeMailto: "leave@ai.example"))
    }

    @Test func latin1AndPlainMail() {
        let raw = "Subject: Hallo\nContent-Type: text/plain; charset=iso-8859-1\nContent-Transfer-Encoding: quoted-printable\n\nGr=FC=DFe"
        let mail = MIMEParser.parse(raw)
        #expect(mail.readableText == "Grüße")
        #expect(BulkInfo.from(headers: mail.headers).isBulk == false)
    }

    @Test func precedenceAndListIdCountAsBulk() {
        #expect(BulkInfo.from(headers: ["precedence": "bulk"]).isBulk)
        #expect(BulkInfo.from(headers: ["list-id": "<dev.lists.example>"]).listID == "<dev.lists.example>")
        #expect(BulkInfo.from(headers: ["auto-submitted": "no"]).isBulk == false)
        #expect(BulkInfo.from(headers: ["list-unsubscribe": "<https://x/u>"]).oneClick == false, "no POST header → open the page instead")
    }

    @Test func newsletterTablesKeepStructureAndLinks() {
        let html = """
            <table><tr><td><h2>Swift</h2></td></tr>
            <tr><td><a href="https://swift.org/blog/6-4">Swift 6.4 released</a> — new concurrency checks.</td></tr>
            <tr><td><a href="mailto:x@y">mail us</a> <a href="https://t.example/pixel"><img src="p.gif"></a></td></tr></table>
            """
        #expect(NewsletterText.extract(html) == "Swift\nSwift 6.4 released (https://swift.org/blog/6-4) — new concurrency checks.\nmail us")
    }
}

@Suite struct SenderRuleTests {
    @Test func exactBeatsDomain() {
        var book = SenderRuleBook()
        book.set("@shop.example", .junk)
        book.set("Deals@Shop.example", .digest)
        #expect(book.action(for: "deals@shop.example") == .digest)
        #expect(book.action(for: "promo@shop.example") == .junk)
        #expect(book.action(for: "anna@example.org") == nil)
        book.remove("@shop.example")
        #expect(book.action(for: "promo@shop.example") == nil)
    }

    @Test func groupsOnlyListMailAndRuledSenders() {
        let list = BulkInfo(isBulk: true, unsubscribeURL: "https://u")
        let messages = [
            MailMessage(id: "1", account: "A", sender: "News <news@a.example>", subject: "One", date: Date(timeIntervalSince1970: 100), isRead: false, bulk: list),
            MailMessage(id: "2", account: "A", sender: "News <news@a.example>", subject: "Two", date: Date(timeIntervalSince1970: 200), isRead: false, bulk: BulkInfo(isBulk: true)),
            MailMessage(id: "3", account: "A", sender: "Anna <anna@x.org>", subject: "Hi", date: .now, isRead: false, bulk: BulkInfo()),
            MailMessage(id: "4", account: "A", sender: "Boss <boss@corp.example>", subject: "Status", date: .now, isRead: false, bulk: BulkInfo()),
        ]
        var rules = SenderRuleBook()
        rules.set("boss@corp.example", .keep)
        let groups = MailTriage.groups(messages, rules: rules)
        #expect(groups.map(\.address) == ["news@a.example", "boss@corp.example"])
        #expect(groups[0].messages.map(\.subject) == ["Two", "One"], "newest first")
        #expect(groups[0].bulk.canUnsubscribe, "unsubscribe info from any message of the sender")
        #expect(groups[1].rule == .keep)
    }
}

/// Real Mail, read-only; prints only counts. `MAIL_LIVE=1 swift test --filter MailCleanupLiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAIL_LIVE"] == "1"))
struct MailCleanupLiveTests {
    @Test func headersAndSourcesFromRealMail() async throws {
        let source = AppleMailSource()
        var started = ContinuousClock.now
        let messages = try await source.recentWithHeaders(days: 2, unreadOnly: true, limit: 40)
        let headerTime = ContinuousClock.now - started
        let groups = MailTriage.groups(messages, rules: SenderRuleBook())
        started = ContinuousClock.now
        let raw = try await source.sources(ids: Array(messages.prefix(5).map(\.id)))
        let parsed = raw.values.map(MIMEParser.parse)
        print("""
            MAIL CLEANUP LIVE: \(messages.count) unread with headers in \(headerTime); \
            \(messages.filter { $0.bulk?.isBulk == true }.count) mailing-list, \(groups.count) sender groups, \
            \(groups.filter(\.bulk.canUnsubscribe).count) can unsubscribe (\(groups.filter(\.bulk.oneClick).count) one-click); \
            \(raw.count) sources in \(ContinuousClock.now - started), readable text for \(parsed.filter { $0.readableText.count > 100 }.count)
            """)
        #expect(!messages.isEmpty)
        #expect(raw.count == min(5, messages.count))
    }

    /// The /cleanup pipeline on real mail without rules, so nothing is moved. Counts only.
    @Test func cleanupPipelineWithoutRulesMovesNothing() async throws {
        let started = ContinuousClock.now
        let result = try await MailCleanup.run(
            source: AppleMailSource(), rules: SenderRuleBook(), topics: NewsletterDigest.defaultTopics,
            model: MailModel(provider: OllamaProvider(), model: "gemma4:26b"))
        let suggested = Dictionary(grouping: result.groups.compactMap(\.suggestion), by: \.self).mapValues(\.count)
        print("CLEANUP LIVE: \(result.groups.count) senders, suggestions \(suggested), junked \(result.junked), in \(ContinuousClock.now - started)")
        #expect(result.junked == 0)
    }

    /// Real newsletters through the local model; prints counts and timings only, never content.
    @Test func suggestionsAndExtractionOnRealNewsletters() async throws {
        let source = AppleMailSource()
        let model = MailModel(provider: OllamaProvider(), model: "gemma4:26b")
        let messages = try await source.recentWithHeaders(days: 3, unreadOnly: true, limit: 40)
        let groups = MailTriage.groups(messages, rules: SenderRuleBook())
        var started = ContinuousClock.now
        let suggestions = try await SenderAdvisor.suggest(Array(groups.prefix(12)), topics: NewsletterDigest.defaultTopics, rules: SenderRuleBook(), model: model)
        let counts = Dictionary(grouping: suggestions.values, by: \.action).mapValues(\.count)
        print("MAIL DIGEST LIVE: \(suggestions.count)/\(min(12, groups.count)) suggestions in \(ContinuousClock.now - started): \(counts)")

        let sample = groups.prefix(4).compactMap(\.messages.first)
        let raw = try await source.sources(ids: sample.map(\.id))
        for message in sample {
            guard let mime = raw[message.id] else { continue }
            let text = MIMEParser.parse(mime).readableText
            started = ContinuousClock.now
            let proposedCount: Int
            do {
                let (system, user) = NewsletterDigest.prompt(text: text, sender: message.senderName, subject: message.subject, topics: NewsletterDigest.defaultTopics)
                struct Reply: Decodable { var items: [DigestItem] }
                let reply = try await model.json(Reply.self, system: system, user: user, schema: NewsletterDigest.schema(topics: NewsletterDigest.defaultTopics), maxTokens: 2_000)
                proposedCount = reply.items.count
                let kept = NewsletterDigest.validated(reply.items, text: text, topics: NewsletterDigest.defaultTopics, source: "x")
                print("MAIL DIGEST LIVE: \(text.count) chars → \(proposedCount) items, \(kept.count) with verified links, in \(ContinuousClock.now - started)")
            } catch {
                print("MAIL DIGEST LIVE: extraction failed after \(ContinuousClock.now - started)")
            }
        }
    }
}

@Suite struct UnsubscribeTests {
    @Test func picksTheBestMethod() {
        #expect(UnsubscribeMethod.best(for: BulkInfo(unsubscribeURL: "https://u.example/x", oneClick: true)) == .oneClick(URL(string: "https://u.example/x")!))
        #expect(UnsubscribeMethod.best(for: BulkInfo(unsubscribeURL: "https://u.example/x", unsubscribeMailto: "a@b")) == .openPage(URL(string: "https://u.example/x")!))
        #expect(UnsubscribeMethod.best(for: BulkInfo(unsubscribeMailto: "leave@b.example?subject=stop%20it")) == .mailto(address: "leave@b.example", subject: "stop it"))
        #expect(UnsubscribeMethod.best(for: BulkInfo(unsubscribeURL: "https://192.168.1.4/u", oneClick: true)) == nil, "never a LAN address")
        #expect(UnsubscribeMethod.best(for: BulkInfo()) == nil)
    }
}

@Suite struct NewsletterDigestTests {
    static let text = """
        Issue 12
        Gemma 5 runs on a laptop (https://ai.example/gemma) — benchmarks inside.
        Swift Testing gets traits (https://swift.example/traits)
        Sponsored: buy our VPN (https://ads.example/vpn)
        """

    @Test func dropsInventedLinksOtherTopicsAndDuplicates() {
        let items = [
            DigestItem(topic: "AI / LLMs", title: "Gemma 5 on a laptop", summary: "Runs locally.", url: "https://ai.example/gemma"),
            DigestItem(topic: "AI / LLMs", title: "Duplicate", summary: "", url: "https://ai.example/gemma"),
            DigestItem(topic: "Swift / iOS / macOS", title: "Made up", summary: "", url: "https://swift.example/invented"),
            DigestItem(topic: "Security", title: "VPN", summary: "", url: "https://ads.example/vpn"),
        ]
        let kept = NewsletterDigest.validated(items, text: Self.text, topics: NewsletterDigest.defaultTopics, source: "AI Weekly")
        #expect(kept.map(\.title) == ["Gemma 5 on a laptop"])
        #expect(kept[0].source == "AI Weekly")
    }

    @Test func pipelineDigestsArchivesAndListsNewSenders() async throws {
        let digestSender = MailMessage(id: "<n1@x>", account: "A", sender: "AI Weekly <hi@ai.example>", subject: "Issue 12", date: .now, isRead: false, bulk: BulkInfo(isBulk: true))
        let unknown = MailMessage(id: "<n2@x>", account: "A", sender: "Deals <deals@shop.example>", subject: "-50%", date: .now, isRead: false, bulk: BulkInfo(isBulk: true))
        let mail = FakeMailSource(messages: [digestSender, unknown])
        mail.rawSources = ["<n1@x>": "Content-Type: text/plain\n\n" + Self.text]
        var rules = SenderRuleBook()
        rules.set("hi@ai.example", .digest)
        let reply = #"{"items":[{"topic":"AI / LLMs","title":"Gemma 5 on a laptop","summary":"Runs locally.","url":"https://ai.example/gemma"}]}"#
        let model = MailModel(provider: ScriptedProvider(reply: reply), model: "m")

        let result = try await NewsletterDigest.run(source: mail, rules: rules, topics: NewsletterDigest.defaultTopics, model: model, archive: true)
        #expect(result.items.count == 1)
        #expect(result.digested.map(\.id) == ["<n1@x>"])
        #expect(result.undecided.map(\.address) == ["deals@shop.example"])
        let moves = mail.moves.withLock { $0 }
        #expect(moves.count == 1 && moves[0].ids == ["<n1@x>"] && moves[0].destination == .archive && moves[0].markRead)

        let markdown = NewsletterDigest.markdown(result, topics: NewsletterDigest.defaultTopics)
        #expect(markdown.contains("### AI / LLMs\n- [Gemma 5 on a laptop](https://ai.example/gemma): Runs locally. — _AI Weekly_"))
        #expect(markdown.contains("New mailing-list senders: Deals. Decide in /cleanup."))
    }

    @Test func failedExtractionLeavesMailInInbox() async throws {
        let message = MailMessage(id: "<n1@x>", account: "A", sender: "AI Weekly <hi@ai.example>", subject: "Issue", date: .now, isRead: false, bulk: BulkInfo(isBulk: true))
        let mail = FakeMailSource(messages: [message])
        mail.rawSources = ["<n1@x>": "Content-Type: text/plain\n\nhello"]
        var rules = SenderRuleBook()
        rules.set("@ai.example", .digest)
        let result = try await NewsletterDigest.run(
            source: mail, rules: rules, topics: NewsletterDigest.defaultTopics,
            model: MailModel(provider: ScriptedProvider(reply: "not json"), model: "m"), archive: true)
        #expect(result.failed.count == 1 && result.digested.isEmpty)
        #expect(mail.moves.withLock { $0 }.isEmpty)
    }

    @Test func suggestionsOnlyForAskedSendersWithExamplesInPrompt() async throws {
        let group = SenderGroup(address: "deals@shop.example", name: "Deals", messages: [sampleMail[3]], bulk: BulkInfo(isBulk: true))
        var rules = SenderRuleBook()
        rules.set("hi@ai.example", .digest)
        let (_, user) = SenderAdvisor.prompt([group], topics: ["AI"], examples: [("AI Weekly", .digest)])
        #expect(user.contains("- AI Weekly: digest"))
        #expect(user.contains("<untrusted source=\"mail\">"))

        let reply = #"{"senders":[{"address":"Deals@Shop.example","action":"junk","reason":"Promotions"},{"address":"other@x","action":"keep","reason":"?"}]}"#
        let found = try await SenderAdvisor.suggest([group], topics: ["AI"], rules: rules, model: MailModel(provider: ScriptedProvider(reply: reply), model: "m"))
        #expect(found.keys.sorted() == ["deals@shop.example"])
        #expect(found["deals@shop.example"]?.action == .junk)
    }
}

/// Extraction quality on a made-up tech newsletter. `OLLAMA_LIVE=1 swift test --filter DigestModelLiveTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OLLAMA_LIVE"] == "1"))
struct DigestModelLiveTests {
    @Test func extractsTopicItemsFromATechNewsletter() async throws {
        let html = """
            <h1>Dev Weekly #212</h1>
            <p><a href="https://example.com/a/qwen-local">Qwen 4 runs locally with 32k context</a> New quantisation keeps quality at 4 bit.</p>
            <p><a href="https://example.com/a/swift-63">What's new in Swift 6.3</a> Typed throws everywhere and faster builds.</p>
            <p>SPONSOR: <a href="https://ads.example.com/vpn">Get 80% off the best VPN</a></p>
            <p><a href="https://example.com/a/ts-58">TypeScript 5.8 beta</a> Better inference for generics.</p>
            <p><a href="https://example.com/a/rust-gui">A Rust GUI toolkit comparison</a> Five toolkits benchmarked.</p>
            <p><a href="https://example.com/jobs">Hiring: Senior Engineer at Acme</a></p>
            """
        let text = NewsletterText.extract(html)
        let started = ContinuousClock.now
        let items = try await NewsletterDigest.extract(
            text: text, sender: "Dev Weekly", subject: "#212", topics: NewsletterDigest.defaultTopics,
            model: MailModel(provider: OllamaProvider(), model: "gemma4:26b"))
        print("DIGEST MODEL LIVE: \(items.count) items in \(ContinuousClock.now - started)")
        for item in items { print("  [\(item.topic)] \(item.title) — \(item.url)") }
        #expect(Set(items.map(\.url)) == ["https://example.com/a/qwen-local", "https://example.com/a/swift-63", "https://example.com/a/ts-58"])
    }
}

@Suite struct MailCleanupRunTests {
    @Test func junkRulesMoveSuggestionsDoNot() async throws {
        let bulk = BulkInfo(isBulk: true, unsubscribeURL: "https://u.example/x", oneClick: true)
        let mail = FakeMailSource(messages: [
            MailMessage(id: "<s1@x>", account: "A", sender: "Spam <promo@spam.example>", subject: "Win", date: .now, isRead: false, bulk: bulk),
            MailMessage(id: "<s2@x>", account: "A", sender: "Spam <promo@spam.example>", subject: "Win again", date: .now, isRead: true, bulk: bulk),
            MailMessage(id: "<d1@x>", account: "A", sender: "AI Weekly <hi@ai.example>", subject: "Issue", date: .now, isRead: false, bulk: bulk),
            MailMessage(id: "<u1@x>", account: "A", sender: "Shop <deals@shop.example>", subject: "-50%", date: .now, isRead: false, bulk: bulk),
            MailMessage(id: "<k1@x>", account: "A", sender: "Bank <alerts@bank.example>", subject: "Statement", date: .now, isRead: false, bulk: bulk),
        ])
        var rules = SenderRuleBook()
        rules.set("@spam.example", .junk)
        rules.set("hi@ai.example", .digest, name: "AI Weekly")
        rules.set("alerts@bank.example", .keep)
        let reply = #"{"senders":[{"address":"deals@shop.example","action":"junk","reason":"Promotions"}]}"#
        let result = try await MailCleanup.run(
            source: mail, rules: rules, topics: ["AI"], model: MailModel(provider: ScriptedProvider(reply: reply), model: "m"))

        let moves = mail.moves.withLock { $0 }
        #expect(moves.count == 1)
        #expect(Set(moves[0].ids) == ["<s1@x>", "<s2@x>"] && moves[0].destination == .junk && moves[0].markRead)
        #expect(result.junked == 2 && result.waitingForDigest == 1)
        #expect(result.groups.map(\.address) == ["deals@shop.example"], "only undecided senders; ruled ones are handled, not shown")
        #expect(result.groups[0].suggestion == .junk && result.groups[0].reason == "Promotions")
        #expect(MailCleanup.summary(result) == "Moved **2** to Junk by your rules. **1 sender** to decide. Your choice becomes a rule that runs automatically from now on. 1 newsletter waits for /digest.")
    }
}

@Suite struct SerialQueueTests {
    @Test func runsOneAtATimeInCallOrder() async throws {
        let queue = SerialQueue()
        let log = Mutex<[String]>([])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    _ = try await queue.run {
                        log.withLock { $0.append("start \(index)") }
                        try await Task.sleep(for: .milliseconds(20))
                        log.withLock { $0.append("end \(index)") }
                        return index
                    }
                }
                // Keep the submission order deterministic.
                try await Task.sleep(for: .milliseconds(2))
            }
            try await group.waitForAll()
        }
        let entries = log.withLock { $0 }
        #expect(entries == (0..<4).flatMap { ["start \($0)", "end \($0)"] })
    }

    @Test func aFailureDoesNotBlockTheNext() async throws {
        let queue = SerialQueue()
        await #expect(throws: MailError.self) { try await queue.run { throw MailError.notFound } }
        #expect(try await queue.run { 42 } == 42)
    }
}

@Suite struct NarrowRuleTests {
    static let list = BulkInfo(isBulk: true, unsubscribeURL: "https://u.example/x")

    func mail(_ sender: String, _ subject: String, bulk: BulkInfo? = list) -> MailMessage {
        MailMessage(id: UUID().uuidString, account: "A", sender: sender, subject: subject, date: .now, isRead: false, bulk: bulk)
    }

    @Test func domainRuleOnlyCoversMailingListAds() {
        var rules = SenderRuleBook()
        rules.set("@brand.example", .junk)
        #expect(rules.action(for: mail("Brand <news@brand.example>", "Black Week: -40% on everything")) == .junk)
        #expect(rules.action(for: mail("Brand <news@brand.example>", "Free delivery this weekend")) == .junk, "ads that mention delivery are still ads")
        #expect(rules.action(for: mail("Brand <news@brand.example>", "Kostenloser Versand ab 50 €")) == .junk)
        #expect(rules.action(for: mail("Brand <orders@brand.example>", "Thanks for shopping with us")) == nil, "order sender")
        #expect(rules.action(for: mail("Brand <service@brand.example>", "Ihre Bestellung 4711 wurde versandt")) == nil)
        #expect(rules.action(for: mail("Brand <service@brand.example>", "Hello", bulk: BulkInfo())) == nil, "not a mailing list")
        #expect(rules.action(for: mail("Brand <service@brand.example>", "Your invoice", bulk: nil)) == nil)
    }

    @Test func addressRuleStillSparesOrderMail() {
        var rules = SenderRuleBook()
        rules.set("info@brand.example", .junk)
        #expect(rules.action(for: mail("Brand <info@brand.example>", "New collection", bulk: BulkInfo())) == .junk, "address rules cover non-list mail")
        #expect(rules.action(for: mail("Brand <info@brand.example>", "Deine Rechnung zur Bestellung 12")) == nil)
        #expect(rules.protects(mail("Brand <info@brand.example>", "Your order #123 has shipped")))
        rules.set("info@brand.example", .keep)
        #expect(rules.action(for: mail("Brand <info@brand.example>", "Your order #123 has shipped")) == .keep)
    }

    @Test func cleanupLeavesOrderMailAndDigestSkipsIt() async throws {
        let messages = [
            mail("Brand <news@brand.example>", "Sale!"),
            mail("Brand <news@brand.example>", "Your order #5 has shipped"),
            mail("Brand <orders@brand.example>", "Bestellbestätigung"),
        ]
        let source = FakeMailSource(messages: messages)
        var rules = SenderRuleBook()
        rules.set("@brand.example", .junk)
        let result = try await MailCleanup.run(source: source, rules: rules, topics: ["AI"], model: nil)
        let moved = source.moves.withLock { $0 }.flatMap(\.ids)
        #expect(moved == [messages[0].id])
        #expect(result.protected == 2)
        #expect(MailCleanup.summary(result).contains("Left 2 order or account mails"))
    }
}

/// Answers the grouping call and the per-mail "ask" call differently.
struct TriageScriptProvider: LLMProvider {
    var id = ProviderID("triage")
    var displayName = "Triage"
    var capabilities: ProviderCapabilities { [.streaming] }
    let grouping: String
    let ask: String

    func listModels() async throws -> [ModelInfo] { [] }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let reply = (request.system ?? "").contains("Sort the user's unread mail") ? grouping : ask
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(reply))
            continuation.yield(.done(nil))
            continuation.finish()
        }
    }
}

@Suite struct TriageTests {
    @Test func rulesAndVIPsBeatTheModelAndAsksAreRead() async throws {
        let messages = [
            MailMessage(id: "<boss@x>", account: "A", sender: "Tom <tom@company.de>", subject: "Budget", date: .now, isRead: false),
            MailMessage(id: "<shop@x>", account: "A", sender: "Shop <deals@shop.example>", subject: "Sale", date: .now, isRead: false, bulk: BulkInfo(isBulk: true)),
            MailMessage(id: "<anna@x>", account: "A", sender: "Anna <anna@x.org>", subject: "Photos", date: .now, isRead: false),
            MailMessage(id: "<bank@x>", account: "A", sender: "Bank <service@bank.example>", subject: "Statement", date: .now, isRead: false),
        ]
        let source = FakeMailSource(messages: messages)
        source.rawSources = ["<boss@x>": "Content-Type: text/plain\n\nCan you send the Q1 numbers by Monday?"]
        var rules = SenderRuleBook()
        rules.set("service@bank.example", .digest)
        // The model calls Tom "automated" (VIPs never are) and numbers 1-2 = Tom, Anna (shop and bank are presorted).
        let grouping = #"{"mails":[{"n":1,"category":"automated"},{"n":2,"category":"needsReply"},{"n":7,"category":"fyi"}]}"#
        let provider = TriageScriptProvider(grouping: grouping, ask: #"{"ask":"wants the Q1 numbers by Monday"}"#)
        let items = await TriageClassifier.classify(
            messages, preferences: MailPreferences(vipSenders: ["tom@company.de"]), rules: rules, source: source, model: (provider, "m"))
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(byID["<boss@x>"]?.category == .fyi, "VIP is never automated")
        #expect(byID["<anna@x>"]?.category == .needsReply)
        #expect(byID["<shop@x>"]?.category == .automated && byID["<bank@x>"]?.category == .automated)
        #expect(byID["<anna@x>"]?.ask == nil, "no body for Anna in the fake → no ask")
        #expect(TriageClassifier.ordered(items).map(\.id).first == "<anna@x>")
    }

    @Test func withoutAModelOnlyPresorts() async {
        let items = await TriageClassifier.classify(sampleMail, preferences: MailPreferences(), rules: SenderRuleBook(), source: FakeMailSource(messages: []), model: nil)
        #expect(items.filter { $0.category == .automated }.map(\.id) == ["<a2@x>", "<a4@x>"])
    }
}

@Suite struct ReplyDrafterTests {
    @Test func aDraftWithoutTheIntentFallsBackToTheUsersWords() async throws {
        let empty = ScriptedProvider(reply: #"{"body":"Hallo Tom,\n\n\nViele Grüße,\nAxel"}"#)
        let body = try await ReplyDrafter.draft(intent: "ja passt, bringe die Zahlen mit", original: "…", message: sampleMail[0], userName: nil, provider: empty, model: "m")
        #expect(body == "ja passt, bringe die Zahlen mit")
        let good = ScriptedProvider(reply: #"{"body":"Hallo Tom,\n\nja, das passt. Ich bringe die Zahlen mit.\n\nViele Grüße"}"#)
        #expect(try await ReplyDrafter.draft(intent: "ja passt, bringe die Zahlen mit", original: "…", message: sampleMail[0], userName: nil, provider: good, model: "m").contains("Zahlen"))
    }
}

@Suite struct RuleTests {
    static let list = BulkInfo(isBulk: true)
    func mail(_ id: String, _ sender: String, _ subject: String, read: Bool = false, bulk: BulkInfo? = nil, date: Date = .now) -> MailMessage {
        MailMessage(id: id, account: "A", sender: sender, subject: subject, date: date, isRead: read, bulk: bulk)
    }

    @Test func appliesEachAutomaticRuleAndSparesOrderMail() async throws {
        let messages = [
            mail("1", "GitHub <notifications@github.com>", "PR merged", bulk: Self.list),
            mail("2", "Shop <news@shop.example>", "Sale", bulk: Self.list),
            mail("3", "Shop <news@shop.example>", "Your order #12 has shipped", bulk: Self.list),
            mail("4", "Status <status@cloud.example>", "All systems normal"),
            mail("5", "Status <status@cloud.example>", "Already read", read: true),
            mail("6", "Spam <x@spam.example>", "Win"),
        ]
        let source = FakeMailSource(messages: messages)
        var rules = SenderRuleBook()
        rules.set("notifications@github.com", .archive)
        rules.set("news@shop.example", .trash)
        rules.set("status@cloud.example", .markRead)
        rules.set("@spam.example", .junk)
        let summary = try await RuleApplier.apply(messages, rules: rules, source: source)
        #expect(summary.archived == 1 && summary.deleted == 1 && summary.markedRead == 1)
        #expect(summary.junked == 0, "domain rules need mailing-list mail")
        #expect(summary.handled["3"] == nil, "order mail is never deleted by a rule")
        #expect(summary.handled["5"] == nil, "already read stays as it is")
        #expect(summary.text == "1 deleted, 1 archived, 1 marked read")
    }

    @Test func backgroundRunOnlyTouchesMailNewerThanTheRule() async throws {
        var rules = SenderRuleBook()
        rules.set("a@x.example", .archive)
        let created = rules.rules[0].createdAt
        let messages = [
            mail("old", "A <a@x.example>", "Before", date: created.addingTimeInterval(-3_600)),
            mail("new", "A <a@x.example>", "After", date: created.addingTimeInterval(60)),
        ]
        let summary = try await RuleApplier.apply(messages, rules: rules, source: FakeMailSource(messages: messages), onlyNewerThanRule: true)
        #expect(Array(summary.handled.keys) == ["new"])
    }

    @Test func importantAndLearnedGroupsDriveTriage() {
        var rules = SenderRuleBook()
        rules.set("anna@x.org", .important)
        rules.set("@company.example", .important)
        rules.setCategory(TriageItem.Category.needsReply.rawValue, for: "Billing@Vendor.example")
        let items = TriageClassifier.presort([
            mail("1", "Anna <anna@x.org>", "Hi", bulk: Self.list),
            mail("2", "Boss <boss@company.example>", "Plan"),
            mail("3", "Vendor <billing@vendor.example>", "Invoice", bulk: Self.list),
        ], preferences: MailPreferences(), rules: rules)
        #expect(items[0].isVIP && items[0].category == .fyi, "important senders are never automated")
        #expect(items[1].isVIP, "domain-wide important applies to every mail of the domain")
        #expect(items[2].category == .needsReply && items[2].learned)
    }

    @Test func oldTriageCardsStillDecode() throws {
        let item = TriageItem(message: sampleMail[0], category: .fyi)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        json.removeValue(forKey: "learned")
        let decoded = try JSONDecoder().decode(TriageItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.learned == false && decoded.id == item.id)
    }

    @Test func oldRuleBooksStillDecode() throws {
        let book = try JSONDecoder().decode(SenderRuleBook.self, from: Data(#"{"rules":[]}"#.utf8))
        #expect(book.categories.isEmpty)
    }
}
