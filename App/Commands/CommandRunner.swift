import Commands
import Foundation
import Persistence
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
                finalize: spec.name == "brief" ? attachDueReminders : nil
            ))
            return .handled
        }
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
