import AppKit
import Automation
import Commands
import Foundation
import Observation
import Persistence
import SwiftData

/// Runs automations: a 30-second check (robust across sleep, no timer math to drift) plus a check
/// after wake; due automations run one at a time, each in its own Chat conversation.
@MainActor
@Observable
final class AutomationScheduler {
    static let runTimeout: Duration = .seconds(15 * 60)
    static let approvalTimeout: TimeInterval = 10 * 60
    static let retryDelay: Duration = .seconds(5 * 60)
    static let maxAttempts = 3

    private(set) var runningAutomation: UUID?
    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var queue: [(id: UUID, attempt: Int)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    init(app: AppModel, container: ModelContainer, notifier: Notifier) {
        self.app = app
        self.container = container
        self.notifier = notifier
    }

    private var context: ModelContext { container.mainContext }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Give Wi-Fi/Tailscale and Ollama a moment after wake.
                Task {
                    try? await Task.sleep(for: .seconds(20))
                    self?.didWake()
                }
            }
        }
        checkDue()
    }

    func runNow(_ automation: Automation) {
        enqueue(automation.id)
    }

    // MARK: Scheduling

    private func enabledAutomations() -> [Automation] {
        (try? context.fetch(FetchDescriptor<Automation>(predicate: #Predicate { $0.enabled }))) ?? []
    }

    func checkDue(now: Date = .now) {
        for automation in enabledAutomations()
        where Schedule.isDue(automation.trigger, lastRun: automation.lastRunAt, enabledAt: automation.enabledAt, now: now) {
            enqueue(automation.id)
        }
    }

    private func didWake() {
        for automation in enabledAutomations() where automation.trigger == .onWake {
            enqueue(automation.id)
        }
        checkDue()
    }

    private func enqueue(_ id: UUID, attempt: Int = 1) {
        guard runningAutomation != id, !queue.contains(where: { $0.id == id }) else { return }
        queue.append((id, attempt))
        if runningAutomation == nil { Task { await processQueue() } }
    }

    private func processQueue() async {
        while !queue.isEmpty {
            let (id, attempt) = queue.removeFirst()
            guard let automation = automation(id) else { continue }
            runningAutomation = id
            await run(automation, attempt: attempt)
            runningAutomation = nil
        }
    }

    private func automation(_ id: UUID) -> Automation? {
        try? context.fetch(FetchDescriptor<Automation>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: Running

    private func run(_ automation: Automation, attempt: Int) async {
        // Marked first, so the 30-second check doesn't queue it again while it runs.
        automation.lastRunAt = .now
        let conversation = Conversation(
            title: "\(automation.name) · \(Date.now.formatted(date: .abbreviated, time: .shortened))",
            task: .chat
        )
        context.insert(conversation)
        let record = AutomationRun(conversationID: conversation.id)
        automation.runs.append(record)
        try? context.save()

        let command = automation.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            finish(record, automation, status: .skipped, summary: "No command or prompt set.")
            return
        }
        if CommandInput(command) != nil {
            if case .failed(let message)? = app.runCommand(command, in: conversation, context: context, onRedirect: { _ in }) {
                finish(record, automation, status: .failed, summary: message)
                return
            }
        } else {
            app.send(command, in: conversation, context: context)
        }

        // Wait for the turn (including any queued messages) to finish.
        let started = ContinuousClock.now
        var approvalSince: Date?
        while app.chat.isStreaming(conversation) {
            try? await Task.sleep(for: .seconds(1))
            let pending = pendingApprovals(in: conversation)
            if !pending.isEmpty {
                if approvalSince == nil {
                    approvalSince = .now
                    record.status = .needsApproval
                    notifier.post(
                        title: automation.name,
                        body: "Needs your approval: \(pending.first?.approvalSummary ?? "a change")",
                        conversationID: conversation.id
                    )
                } else if let since = approvalSince, Date.now.timeIntervalSince(since) > Self.approvalTimeout {
                    for step in pending { app.approvals.resolve(step.id, granted: false) }
                }
            }
            if ContinuousClock.now - started > Self.runTimeout {
                app.chat.stop(conversation)
                finish(record, automation, status: .failed, summary: "Stopped after 15 minutes.")
                return
            }
        }

        let reply = conversation.orderedMessages.last { $0.role == .assistant }
        if let error = reply?.errorText {
            // Ollama down (e.g. right after wake): retry a couple of times before reporting.
            if error.localizedCaseInsensitiveContains("not reachable"), attempt < Self.maxAttempts {
                finish(record, automation, status: .failed, summary: "\(error) Retrying in 5 minutes.", notify: false)
                Task {
                    try? await Task.sleep(for: Self.retryDelay)
                    enqueue(automation.id, attempt: attempt + 1)
                }
                return
            }
            finish(record, automation, status: .failed, summary: error)
        } else {
            finish(record, automation, status: .succeeded, summary: Self.summary(of: reply?.content ?? ""))
        }
    }

    private func pendingApprovals(in conversation: Conversation) -> [ToolStep] {
        conversation.orderedMessages.last?.toolSteps.filter { $0.status == .awaitingApproval } ?? []
    }

    private func finish(_ record: AutomationRun, _ automation: Automation, status: AutomationRun.Status, summary: String, notify: Bool = true) {
        record.status = status
        record.summary = summary
        record.finishedAt = .now
        try? context.save()
        guard notify, automation.notify else { return }
        let title = status == .succeeded ? automation.name : "\(automation.name) failed"
        notifier.post(title: title, body: summary, conversationID: record.conversationID)
    }

    /// First few lines of the reply, without Markdown markers, for the notification.
    static func summary(of content: String) -> String {
        let plain = content
            .replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .joined(separator: " · ")
        return plain.count > 300 ? String(plain.prefix(300)) + "…" : (plain.isEmpty ? "Done." : plain)
    }
}
