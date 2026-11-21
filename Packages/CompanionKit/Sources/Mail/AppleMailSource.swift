import Foundation

/// Apple Mail via JavaScript for Automation in an `osascript` subprocess: never blocks the app, can be
/// timed out, and macOS attributes the Automation permission to ItsMeAgain (the responsible process).
/// Measured on a real inbox: listing ≈ 1.5 s for 80 messages; a single body can take several seconds
/// (Mail downloads it on demand), so bodies are only fetched by `read`.
public struct AppleMailSource: MailSource {
    public init() {}

    public func accounts() async throws -> [String] {
        try await run(["mode": "accounts"], timeout: 20, as: [String].self)
    }

    public func recent(days: Int, unreadOnly: Bool, limit: Int) async throws -> [MailMessage] {
        await Self.accounts.record(
            try await run(["mode": "recent", "days": days, "unreadOnly": unreadOnly, "limit": limit], timeout: 40, as: [MailMessage].self)
        )
    }

    public func search(query: String?, sender: String?, days: Int, limit: Int) async throws -> [MailMessage] {
        await Self.accounts.record(
            try await run(["mode": "search", "query": query ?? "", "sender": sender ?? "", "days": days, "limit": limit], timeout: 60, as: [MailMessage].self)
        )
    }

    /// Uses the raw source (≈50 ms) and parses it here; falls back to Mail's rendered content.
    public func read(id: String) async throws -> MailBody {
        struct Raw: Decodable {
            var message: MailMessage
            var source: String
        }
        let raw = try await run(["mode": "read", "id": id, "accounts": await Self.accounts.map([id])], timeout: 60, as: Raw.self)
        let parsed = MIMEParser.parse(raw.source)
        var text = parsed.readableText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = try await run(["mode": "content", "id": id, "accounts": await Self.accounts.map([id])], timeout: 90, as: String.self)
        }
        var message = raw.message
        message.bulk = BulkInfo.from(headers: parsed.headers)
        return MailBody(message: message, text: text)
    }

    public func recentWithHeaders(days: Int, unreadOnly: Bool, limit: Int) async throws -> [MailMessage] {
        struct Row: Decodable {
            var message: MailMessage
            var headers: String
        }
        let rows = try await run(
            ["mode": "recentHeaders", "days": days, "unreadOnly": unreadOnly, "limit": limit], timeout: 90, as: [Row].self
        )
        return await Self.accounts.record(rows.map { row in
            var message = row.message
            message.bulk = BulkInfo.from(headers: MIMEParser.headers(row.headers))
            return message
        })
    }

    public func sources(ids: [String]) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return try await run(["mode": "sources", "ids": ids, "accounts": await Self.accounts.map(ids)], timeout: 30 + Double(ids.count) * 3, as: [String: String].self)
    }

    /// Changes run one at a time: Mail handles Apple events serially, so parallel moves only wait on
    /// each other and time out. Each one's timeout starts when it actually runs.
    public func move(ids: [String], to destination: MailDestination, markRead: Bool, from origin: MailDestination) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try await Self.changes.run {
            try await run(
                ["mode": "move", "ids": ids, "target": destination.rawValue, "markRead": markRead, "from": origin.rawValue,
                 "accounts": await Self.accounts.map(ids)],
                timeout: 60 + Double(ids.count) * 3, as: Int.self
            )
        }
    }

    public func markRead(ids: [String], _ read: Bool) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try await Self.changes.run {
            try await run(["mode": "markRead", "ids": ids, "read": read, "accounts": await Self.accounts.map(ids)], timeout: 30 + Double(ids.count) * 2, as: Int.self)
        }
    }

    static let changes = SerialQueue()
    static let accounts = MessageAccounts()

    public func createDraft(to: [String], subject: String, body: String, replyTo: String?) async throws -> String {
        try await run(
            ["mode": "draft", "to": to, "subject": subject, "body": body, "replyTo": replyTo ?? "",
             "accounts": await Self.accounts.map(replyTo.map { [$0] } ?? [])],
            timeout: 60, as: String.self
        )
    }

    // MARK: Runner

    private func run<T: Decodable>(_ arguments: [String: Any], timeout: TimeInterval, as type: T.Type) async throws -> T {
        let input = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let output = try await Self.osascript(Self.script, argument: input, timeout: timeout, what: arguments["mode"] as? String ?? "")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Bad date \(text)")
        }
        let envelope = try decoder.decode(ScriptEnvelope<T>.self, from: Data(output.utf8))
        if let error = envelope.error {
            throw error == "notFound" ? MailError.notFound : MailError.script(error)
        }
        guard let value = envelope.ok else { throw MailError.script("empty result") }
        return value
    }

    static func osascript(_ script: String, argument: String, timeout: TimeInterval, what: String) async throws -> String {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, argument]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.terminateIfRunning() }

        // Read while the process runs (a long body could otherwise fill the pipe and block osascript).
        let (out, err) = await Task.detached {
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = errors.fileHandleForReading.readDataToEndOfFile()
            box.process.waitUntilExit()
            return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }.value

        if box.timedOut { throw MailError.timeout(what) }
        guard process.terminationStatus == 0 else {
            // -1743: Automation permission denied.
            if err.contains("-1743") || err.localizedCaseInsensitiveContains("not authorized") { throw MailError.notAuthorized }
            throw MailError.script(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    /// One script, several modes; always prints {"ok": …} or {"error": …}.
    static let script = #"""
    function run(argv) {
      const args = JSON.parse(argv[0]);
      const Mail = Application("Mail");
      function since(days) { return new Date(Date.now() - days * 86400000); }
      function list(msgs, limit, withHeaders) {
        const n = msgs.length;
        if (n === 0) return [];
        const ids = msgs.messageId(), subjects = msgs.subject(), senders = msgs.sender();
        const dates = msgs.dateReceived(), read = msgs.readStatus(), flagged = msgs.flaggedStatus();
        const rows = [];
        for (let i = 0; i < n; i++) rows.push({ i: i, date: dates[i] });
        rows.sort((a, b) => b.date - a.date);
        // Only the mailing-list headers, to keep the output small.
        const wanted = /^(list-unsubscribe|list-unsubscribe-post|list-id|precedence|auto-submitted):/i;
        return rows.slice(0, limit).map(r => {
          const m = msgs[r.i];
          let account = "";
          try { account = m.mailbox().account().name(); } catch (e) {}
          const message = { id: ids[r.i], account: account, sender: senders[r.i], subject: subjects[r.i] || "(no subject)",
                            date: dates[r.i].toISOString(), isRead: read[r.i], isFlagged: flagged[r.i] };
          if (!withHeaders) return message;
          const lines = (m.allHeaders() || "").replace(/\r\n[ \t]+/g, " ").split(/\r?\n/);
          return { message: message, headers: lines.filter(line => wanted.test(line)).join("\n") };
        });
      }
      // A message by Message-ID — only in its own account when that is known (the same ID can exist
      // in several accounts). Unknown account and copies in several accounts: refuse, never guess.
      function candidatesFor(id) {
        const bare = id.replace(/^<|>$/g, "");
        return [id, bare, "<" + bare + ">"];
      }
      function accountNamed(name) {
        if (!name) return null;
        try { const account = Mail.accounts.byName(name); account.name(); return account; } catch (e) { return null; }
      }
      function searchAccount(account, id, kind) {
        const candidates = candidatesFor(id);
        // The expected folder first, then the account's top-level folders (Gmail keeps inbox mail in
        // "All Mail"). Never a full recursive scan: that can keep Mail busy for minutes.
        const first = folder(account, kind || "inbox");
        const boxes = (first ? [first] : []).concat(account.mailboxes());
        for (const box of boxes) {
          for (const candidate of candidates) {
            try {
              const found = box.messages.whose({ messageId: candidate });
              if (found.length > 0) return found[0];
            } catch (e) {}
          }
        }
        return null;
      }
      function findIn(id, kind) {
        const account = accountNamed((args.accounts || {})[id]);
        if (account) return searchAccount(account, id, kind);
        // Account unknown: the unified inbox, but only if the mail exists in exactly one account.
        if (kind && kind !== "inbox") return null;
        const matches = [];
        for (const candidate of candidatesFor(id)) {
          const found = Mail.inbox.messages.whose({ messageId: candidate });
          for (let i = 0; i < found.length; i++) matches.push(found[i]);
          if (matches.length > 0) break;
        }
        if (matches.length === 0) return null;
        const owners = new Set(matches.map(m => { try { return m.mailbox().account().name(); } catch (e) { return "?"; } }));
        if (owners.size > 1) throw new Error("This mail is in several accounts (" + Array.from(owners).join(", ") + "); run /triage again so I know which one.");
        return matches[0];
      }
      function find(id) { return findIn(id, "inbox"); }
      function summary(m) {
        let account = "";
        try { account = m.mailbox().account().name(); } catch (e) {}
        return { id: m.messageId(), account: account, sender: m.sender(), subject: m.subject() || "(no subject)",
                 date: m.dateReceived().toISOString(), isRead: m.readStatus(), isFlagged: m.flaggedStatus() };
      }
      // Special folders differ per provider and language; search two levels deep.
      const folderNames = {
        junk: /^(junk|spam|junk e-?mail|junk-e-mail|bulk mail|werbung)$/i,
        archive: /^(archive|archiv|all mail|alle nachrichten)$/i,
        trash: /^(trash|deleted messages|deleted items|papierkorb|gel(ö|oe)schte (objekte|elemente|nachrichten)|bin|corbeille)$/i,
        inbox: /^(inbox|posteingang)$/i,
      };
      // The folder walk takes seconds per account; do it once per account and kind per call.
      const folderCache = {};
      function folder(account, kind) {
        const key = account.id() + "/" + kind;
        if (!(key in folderCache)) folderCache[key] = findFolder(account, kind);
        return folderCache[key];
      }
      function findFolder(account, kind) {
        const queue = account.mailboxes().map(m => [m, 0]);
        while (queue.length) {
          const [box, depth] = queue.shift();
          // Exchange may store "ö" as "o" + combining diaeresis; compare in composed form.
          const name = box.name().normalize("NFC").replace(/^\[(gmail|google mail)\]\//i, "");
          if (folderNames[kind].test(name)) return box;
          if (depth < 1) { try { box.mailboxes().forEach(child => queue.push([child, depth + 1])); } catch (e) {} }
        }
        return null;
      }
      try {
        switch (args.mode) {
          case "accounts":
            return JSON.stringify({ ok: Mail.accounts.name() });
          case "recent": {
            let query = { dateReceived: { _greaterThan: since(args.days) } };
            if (args.unreadOnly) query = { _and: [query, { readStatus: false }] };
            return JSON.stringify({ ok: list(Mail.inbox.messages.whose(query), args.limit) });
          }
          case "search": {
            const parts = [{ dateReceived: { _greaterThan: since(args.days) } }];
            if (args.query) parts.push({ subject: { _contains: args.query } });
            if (args.sender) parts.push({ sender: { _contains: args.sender } });
            return JSON.stringify({ ok: list(Mail.inbox.messages.whose({ _and: parts }), args.limit) });
          }
          case "read": {
            const m = find(args.id);
            if (!m) return JSON.stringify({ error: "notFound" });
            return JSON.stringify({ ok: { message: summary(m), source: (m.source() || "").substring(0, 400000) } });
          }
          case "content": {
            const m = find(args.id);
            if (!m) return JSON.stringify({ error: "notFound" });
            return JSON.stringify({ ok: (m.content() || "").substring(0, 20000) });
          }
          case "recentHeaders": {
            let query = { dateReceived: { _greaterThan: since(args.days) } };
            if (args.unreadOnly) query = { _and: [query, { readStatus: false }] };
            return JSON.stringify({ ok: list(Mail.inbox.messages.whose(query), args.limit, true) });
          }
          case "sources": {
            const out = {};
            args.ids.forEach(id => { const m = find(id); if (m) out[id] = (m.source() || "").substring(0, 400000); });
            return JSON.stringify({ ok: out });
          }
          case "move": {
            let moved = 0;
            args.ids.forEach(id => {
              const m = findIn(id, args.from);
              if (!m) return;
              if (args.markRead) m.readStatus = true;
              // Delete: Mail's own command moves the message to the trash Mail uses for that account,
              // whatever the folder is called (no name guessing).
              if (args.target === "trash") {
                Mail.delete(m);
                moved++;
                return;
              }
              let account = null;
              try { account = m.mailbox().account(); } catch (e) {}
              const target = account ? folder(account, args.target) : null;
              if (!target) {
                let names = "";
                try { names = account.mailboxes.name().join(", "); } catch (e) {}
                throw new Error("No " + args.target + " folder found in " + (account ? account.name() : "this message's account")
                  + (names ? " (folders: " + names + ")" : ""));
              }
              if (args.target === "junk") m.junkMailStatus = true;
              m.mailbox = target;
              moved++;
            });
            return JSON.stringify({ ok: moved });
          }
          case "markRead": {
            let changed = 0;
            args.ids.forEach(id => { const m = find(id); if (m) { m.readStatus = args.read; changed++; } });
            return JSON.stringify({ ok: changed });
          }
          case "draft": {
            let draft;
            if (args.replyTo) {
              const original = find(args.replyTo);
              if (!original) return JSON.stringify({ error: "notFound" });
              draft = Mail.reply(original, { openingWindow: true, replyToAll: false });
              draft.content = args.body + "\n\n" + draft.content();
            } else {
              draft = Mail.OutgoingMessage({ subject: args.subject, content: args.body, visible: true });
              Mail.outgoingMessages.push(draft);
              args.to.forEach(address => draft.toRecipients.push(Mail.Recipient({ address: address })));
            }
            Mail.activate();
            return JSON.stringify({ ok: "Draft opened in Mail — review and send it there." });
          }
        }
        return JSON.stringify({ error: "unknown mode" });
      } catch (e) {
        return JSON.stringify({ error: String(e) });
      }
    }
    """#
}

/// What the script prints: {"ok": value} or {"error": message}.
private struct ScriptEnvelope<V: Decodable>: Decodable {
    var ok: V?
    var error: String?
}

/// `Process` isn't Sendable; terminating from the timeout queue is safe.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var didTimeOut = false

    var timedOut: Bool { lock.withLock { didTimeOut } }

    func terminateIfRunning() {
        lock.withLock {
            guard process.isRunning else { return }
            didTimeOut = true
            process.terminate()
        }
    }
}

/// Runs operations strictly one after another, in call order.
actor SerialQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

/// Which account each listed message belongs to. The same Message-ID can exist in several accounts
/// (one newsletter sent to two addresses); actions must only ever touch the copy in its own account.
actor MessageAccounts {
    private var accounts: [String: String] = [:]

    @discardableResult
    func record(_ messages: [MailMessage]) -> [MailMessage] {
        for message in messages where !message.account.isEmpty { accounts[message.id] = message.account }
        if accounts.count > 20_000 { accounts.removeAll() }
        return messages
    }

    func map(_ ids: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for id in ids { if let account = accounts[id] { result[id] = account } }
        return result
    }
}
