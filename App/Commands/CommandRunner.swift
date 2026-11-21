import Commands
import Foundation
import Obsidian
import Persistence
import PersonalData
import Routing
import SwiftData

/// How a command overrides a normal turn.
struct CommandInvocation {
    var modelText: String
    var task: TaskKind
    var tools: [String]?
    var autoApproved: Set<String>
    var finalize: (@MainActor (StoredMessage) async -> Void)?
}

enum CommandOutcome: Equatable {
    case handled
    case failed(String)
}

extension AppModel {
    /// Runs `text` if it is a slash command; returns nil for normal messages.
    ///
    /// Personal commands always run in Chat mode: from a Code, Translate or Research conversation they
    /// continue in a new Chat conversation, handed to `onRedirect` (the main window selects it, the
    /// quick panel adopts it).
    func runCommand(
        _ text: String,
        in conversation: Conversation,
        context: ModelContext,
        onRedirect: (Conversation) -> Void
    ) -> CommandOutcome? {
        guard let input = CommandInput(text) else { return nil }
        guard let spec = commands.registry.command(named: input.name) else {
            return .failed("Unknown command /\(input.name). Type / to see all commands.")
        }

        var target = conversation
        if spec.scope == .personal && conversation.task != .chat && !conversation.autoRoute {
            target = Conversation(task: .chat)
            context.insert(target)
            onRedirect(target)
        }

        switch spec.kind {
        case .native(let handler):
            return runNative(handler, input: input, text: text, in: target, context: context, onRedirect: onRedirect)
        case .prompt(let prompt):
            let expanded = TemplateExpander.expand(prompt.template, input: input)
            send(text, in: target, context: context, command: CommandInvocation(
                modelText: expanded, task: prompt.task, tools: prompt.tools,
                autoApproved: prompt.autoApproved.union(prompt.task == .chat ? standingApprovals : []),
                finalize: spec.name == "brief" ? finishBrief : nil
            ))
            return .handled
        }
    }

    /// After the brief: due reminders underneath, and (if set) the day plan and brief into the daily note.
    private var finishBrief: @MainActor (StoredMessage) async -> Void {
        { [weak self] reply in
            guard let self else { return }
            await attachDueReminders(reply)
            guard briefToDailyNote, vaults.main != nil else { return }
            do {
                let path = try await writeDayPlan(brief: reply.content)
                reply.content += "\n\n_Written to today's daily note: \(path)_"
            } catch {
                reply.content += "\n\n_Couldn't write the daily note: \(error.localizedDescription)_"
            }
        }
    }

    /// Today's timed events (not declined, not all-day) as Day Planner entries, plus the brief.
    func writeDayPlan(brief: String?) async throws -> String {
        guard let main = vaults.main else { throw VaultError.invalid("No Obsidian vault is enabled.") }
        var plan: [DayPlanEntry] = []
        if EventKitStore.eventsAuthorized {
            let start = Calendar.current.startOfDay(for: .now)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
            plan = try await EventKitStore.shared.events(from: start, to: end)
                .filter(\.blocksTime)
                .map { DayPlanEntry(start: $0.start, end: $0.end, title: $0.title) }
        }
        return try main.updateDailyNote(plan: plan, brief: brief)
    }

    /// The brief's answer gets today's due reminders as clickable rows underneath.
    private var attachDueReminders: @MainActor (StoredMessage) async -> Void {
        { [weak self] reply in
            guard let self else { return }
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
            if let due = try? await dueReminders(before: tomorrow), !due.isEmpty {
                reply.attachments = [.reminders(title: "Reminders due", items: due)]
            }
        }
    }

    private func runNative(
        _ handler: String,
        input: CommandInput,
        text: String,
        in conversation: Conversation,
        context: ModelContext,
        onRedirect: (Conversation) -> Void
    ) -> CommandOutcome {
        switch handler {
        case "help":
            if conversation.messages.isEmpty { conversation.title = "Commands" }
            conversation.append(role: .user, content: text)
            conversation.append(role: .assistant, content: helpText())
            try? context.save()
            return .handled

        case "new":
            var task = lastTask
            if let raw = input.positional.first {
                guard let parsed = TaskKind(rawValue: raw.lowercased()) else { return .failed(Self.taskUsage("/new")) }
                task = parsed
            }
            let fresh = Conversation(task: task)
            context.insert(fresh)
            try? context.save()
            onRedirect(fresh)
            return .handled

        case "task":
            guard let raw = input.positional.first, let task = TaskKind(rawValue: raw.lowercased()) else {
                return .failed(Self.taskUsage("/task"))
            }
            select(task, for: conversation)
            return .handled

        case "auto":
            selectAuto(for: conversation)
            return .handled

        case "inbox":
            return runInboxCommand(input: input, text: text, in: conversation, context: context)

        case "cleanup":
            return runCleanupCommand(text: text, in: conversation, context: context)

        case "digest":
            return runDigestCommand(input: input, text: text, in: conversation, context: context)

        case "spelling", "flashcard", "learn":
            return runLearningCommand(handler, input: input, text: text, in: conversation, context: context)

        case "mcp":
            if conversation.messages.isEmpty { conversation.title = "MCP servers" }
            conversation.append(role: .user, content: text, task: conversation.task)
            conversation.append(role: .assistant, content: mcp.markdown + "\n\n_Tools from MCP servers are offered in Chat (local models only). Each call asks first unless you marked the tool read-only in Settings._", task: conversation.task)
            try? context.save()
            return .handled

        case "weather":
            guard weather.place != nil else { return .failed("Choose your place first: Settings → Assistant → Weather.") }
            guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
            if conversation.messages.isEmpty { conversation.title = text }
            conversation.append(role: .user, content: text, task: conversation.task)
            let reply = conversation.append(role: .assistant, content: "_Checking the weather…_", task: conversation.task)
            try? context.save()
            let weather = weather
            chat.run(in: conversation, context: context) {
                await weather.refresh()
                reply.content = weather.markdown
            }
            return .handled

        case "important":
            let sender = input.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sender.isEmpty else { return .failed("Usage: /important tom@company.de (or @company.de, or a name)") }
            addImportantSender(sender)
            if conversation.messages.isEmpty { conversation.title = text }
            conversation.append(role: .user, content: text, task: .chat)
            conversation.append(role: .assistant, content: "**\(sender)** is now an important sender: new mail notifies you and always comes first. "
                + "All important senders: \(importantSendersList.joined(separator: ", ")). Remove one in Settings → Assistant → Mail.", task: .chat)
            try? context.save()
            return .handled

        case "yt-playlist", "yt", "yt-next", "einordnen":
            return runClippingCommand(handler, input: input, text: text, in: conversation, context: context)

        case "jira", "myjira":
            return runJiraCommand(handler, input: input, text: text, in: conversation, context: context)

        case "dayplan":
            guard vaults.main != nil else { return .failed("No Obsidian vault is enabled. Choose one in Settings → Assistant → Obsidian.") }
            guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
            if conversation.messages.isEmpty { conversation.title = text }
            conversation.append(role: .user, content: text, task: .chat)
            let reply = conversation.append(role: .assistant, content: "", task: .chat)
            try? context.save()
            chat.run(in: conversation, context: context) { [self] in
                do {
                    try await ensureCalendarAccess(reminders: false)
                    let path = try await writeDayPlan(brief: nil)
                    reply.content = "Today's events are in the Day Planner section of \(path)."
                } catch {
                    reply.errorText = error.localizedDescription
                }
            }
            return .handled

        case "triage":
            return runTriageCommand(input: input, text: text, in: conversation, context: context)

        case "news":
            guard !chat.isStreaming(conversation) else { return .failed("Wait for the current reply to finish.") }
            if conversation.messages.isEmpty { conversation.title = text }
            conversation.append(role: .user, content: text, task: .chat)
            let reply = conversation.append(role: .assistant, content: "_Checking your feeds…_", task: .chat)
            try? context.save()
            let topic = input.arguments.isEmpty ? nil : input.arguments
            let news = news
            chat.run(in: conversation, context: context) {
                await news.refreshIfStale()
                reply.content = news.markdown(topic: topic)
            }
            return .handled

        case "appointments":
            return runAppointmentsCommand(input: input, text: text, in: conversation, context: context)

        case "watched":
            return runWatchedCommand(text: text, in: conversation, context: context)

        case _ where Self.obsidianHandlers.contains(handler):
            return runObsidianCommand(handler, input: input, text: text, in: conversation, context: context)

        case _ where Self.memoryHandlers.contains(handler):
            return runMemoryCommand(handler, input: input, text: text, in: conversation, context: context)

        case _ where Self.calendarHandlers.contains(handler):
            return runCalendarCommand(handler, input: input, text: text, in: conversation, context: context)

        default:
            return .failed("/\(input.name) isn't available yet.")
        }
    }

    private static func taskUsage(_ command: String) -> String {
        "Usage: \(command) " + TaskKind.allCases.map(\.rawValue).joined(separator: "|")
    }

    private func helpText() -> String {
        func line(_ spec: CommandSpec) -> String {
            "- **/\(spec.name)**" + (spec.argumentHint.map { " `\($0)`" } ?? "") + " — \(spec.summary)"
        }
        let all = commands.registry.commands
        let builtIn = all.filter { if case .builtIn = $0.source { true } else { false } }
        let user = all.filter { if case .user = $0.source { true } else { false } }
        var text = "**Commands**\n\n" + builtIn.map(line).joined(separator: "\n")
        if !user.isEmpty {
            text += "\n\n**Your commands**\n\n" + user.map(line).joined(separator: "\n")
        }
        text += "\n\nAdd your own as Markdown files in Settings → Commands."
        return text
    }
}
