import AppKit
import Foundation
import Mail
import Observation
import Persistence
import PersonalData
import SwiftData

/// Checks new mail every five minutes (and after wake): important senders get a notification per
/// address, appointments in mail become proposals to approve. Results go into one "Mail watch"
/// conversation that the notifications open. Reads only; nothing is added to the calendar without a click.
@MainActor
@Observable
final class MailWatcher {
    static let interval: TimeInterval = 5 * 60
    /// Mails read for appointments per check (bodies cost up to a second each, plus the model).
    static let scanBatch = 25

    private(set) var isChecking = false
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "mailWatchLastCheck") as? Date

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// Mail already reported (important senders) and already read for appointments.
    @ObservationIgnored private var notified = Set(UserDefaults.standard.stringArray(forKey: "mailWatchNotified") ?? [])
    @ObservationIgnored private var scanned = Set(UserDefaults.standard.stringArray(forKey: "mailWatchScanned") ?? [])
    /// Appointments already proposed (so each is asked about once).
    @ObservationIgnored private var proposed = Set(UserDefaults.standard.stringArray(forKey: "mailWatchProposed") ?? [])

    init(app: AppModel, container: ModelContainer) {
        self.app = app
        self.container = container
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    self?.checkSoon()
                }
            }
        }
        // A first look shortly after launch.
        Task {
            try? await Task.sleep(for: .seconds(20))
            checkSoon()
        }
    }

    func checkSoon() {
        guard !isChecking, app.mailEnabled, app.mailWatchEnabled else { return }
        Task { await check() }
    }

    // MARK: Checking

    func check() async {
        isChecking = true
        defer { isChecking = false }
        let preferences = app.mailPreferences
        guard let messages = try? await app.mailSource.recent(days: 7, unreadOnly: true, limit: 200).filter(preferences.includes) else { return }

        var important: [(address: String, messages: [MailMessage])] = []
        if app.notifyImportantMail {
            // Only the last two days notify; older unread mail from important senders isn't news.
            let recent = messages.filter { $0.date > Date.now.addingTimeInterval(-2 * 86_400) }
            important = MailWatch.fromImportant(recent, preferences: preferences, seen: notified)
        }
        for group in important { notified.formUnion(group.messages.map(\.id)) }

        var appointments: [AppointmentProposal] = []
        if app.findAppointmentsInMail, !app.chat.isBusy {
            appointments = await scanForAppointments(messages)
        }

        if !important.isEmpty || !appointments.isEmpty {
            await report(important: important, appointments: appointments)
        }
        lastCheck = .now
        persist(known: Set(messages.map(\.id)))
    }

    /// Reads up to `scanBatch` unscanned mails: invitations exactly, other mails through the local
    /// model when they look like they mention an appointment. Junk and digest senders are skipped.
    private func scanForAppointments(_ messages: [MailMessage]) async -> [AppointmentProposal] {
        let rules = app.senderRules
        let candidates = messages.filter { message in
            guard !scanned.contains(message.id) else { return false }
            let rule = rules.action(for: message.senderAddress)
            return rule != .junk && rule != .digest
        }
        let batch = Array(candidates.prefix(Self.scanBatch))
        guard !batch.isEmpty else { return [] }
        let model = try? app.localMailModel()
        guard let sources = try? await app.mailSource.sources(ids: batch.map(\.id)) else { return [] }

        var found: [AppointmentProposal] = []
        for message in batch {
            guard let raw = sources[message.id] else {
                scanned.insert(message.id)
                continue
            }
            let parsed = MIMEParser.parse(raw)
            var proposals = AppointmentFinder.invitations(parsed, mail: message)
            if proposals.isEmpty, let model, AppointmentFinder.mightContainAppointment(subject: message.subject, text: parsed.readableText) {
                do {
                    proposals = try await AppointmentFinder.extract(text: parsed.readableText, mail: message, provider: model.provider, model: model.model)
                } catch {
                    continue  // model busy or down: try this mail again next time
                }
            }
            scanned.insert(message.id)
            found += proposals.filter { !proposed.contains($0.id) }
        }
        // Already in the calendar (an invitation the account accepted on its own): nothing to ask.
        var fresh: [AppointmentProposal] = []
        for proposal in found {
            proposed.insert(proposal.id)
            if await AppointmentCheck.status(of: proposal) != .alreadyInCalendar { fresh.append(proposal) }
        }
        return fresh
    }

    // MARK: Reporting

    private func report(important: [(address: String, messages: [MailMessage])], appointments: [AppointmentProposal]) async {
        let context = container.mainContext
        let conversation = watchConversation(in: context)
        var lines: [String] = []
        if !important.isEmpty {
            lines.append("**New from important senders**")
            for group in important {
                let name = group.messages[0].senderName
                lines.append("\n**\(name)** · \(group.address) (\(group.messages.count))")
                lines += group.messages.map { MailFormatter.line($0, preferences: app.mailPreferences, markdown: true) }
            }
        }
        if !appointments.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(appointments.count == 1 ? "**An appointment in your mail** — add it?" : "**\(appointments.count) appointments in your mail** — add them?")
        }
        let reply = conversation.append(role: .assistant, content: lines.joined(separator: "\n"), task: .chat)
        if !appointments.isEmpty { reply.attachments = [.appointments(appointments)] }
        conversation.updatedAt = .now
        try? context.save()

        // One notification per sender (at most five), then one per appointment (at most three).
        let preview = app.notifyWithPreview
        for group in important.prefix(5) {
            let name = group.messages[0].senderName
            let title = group.messages.count == 1 ? "Mail from \(name)" : "\(group.messages.count) new mails from \(name)"
            app.notifier.post(title: title, body: preview ? MailWatch.notificationBody(group.messages) : group.address, conversationID: conversation.id)
        }
        if important.count > 5 {
            app.notifier.post(title: "Mail from \(important.count - 5) more important senders", body: "", conversationID: conversation.id)
        }
        for proposal in appointments.prefix(3) {
            let status = await AppointmentCheck.status(of: proposal)
            let when = AppointmentCheck.when(proposal)
            app.notifier.post(
                title: "Appointment: " + (preview ? proposal.title : "from \(proposal.sender)"),
                body: "\(when) · \(status.text) — add it?",
                conversationID: conversation.id
            )
        }
    }

    /// The Chat conversation the watcher writes to (created once; recreated if deleted).
    private func watchConversation(in context: ModelContext) -> Conversation {
        if let raw = UserDefaults.standard.string(forKey: "mailWatchConversation"), let id = UUID(uuidString: raw),
            let existing = try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })).first
        {
            return existing
        }
        let conversation = Conversation(title: "Mail watch", task: .chat)
        context.insert(conversation)
        UserDefaults.standard.set(conversation.id.uuidString, forKey: "mailWatchConversation")
        return conversation
    }

    /// Keeps the sets small: only ids still unread in the window matter.
    private func persist(known: Set<String>) {
        notified.formIntersection(known)
        scanned.formIntersection(known)
        UserDefaults.standard.set(Array(notified), forKey: "mailWatchNotified")
        UserDefaults.standard.set(Array(scanned), forKey: "mailWatchScanned")
        UserDefaults.standard.set(Array(proposed.suffix(2_000)), forKey: "mailWatchProposed")
        UserDefaults.standard.set(lastCheck, forKey: "mailWatchLastCheck")
    }

    // MARK: On demand

    /// `/appointments`: every unread mail of the last `days` days, regardless of earlier scans.
    func findAppointments(days: Int, progress: @MainActor (Int, Int) -> Void) async throws -> [AppointmentProposal] {
        let preferences = app.mailPreferences
        let rules = app.senderRules
        let messages = try await app.mailSource.recent(days: days, unreadOnly: true, limit: 300)
            .filter { preferences.includes($0) && rules.action(for: $0.senderAddress) != .junk && rules.action(for: $0.senderAddress) != .digest }
        let model = try? app.localMailModel()
        var found: [AppointmentProposal] = []
        var done = 0
        for start in stride(from: 0, to: messages.count, by: 10) {
            let batch = Array(messages[start..<min(start + 10, messages.count)])
            let sources = try await app.mailSource.sources(ids: batch.map(\.id))
            for message in batch {
                done += 1
                progress(done, messages.count)
                guard let raw = sources[message.id] else { continue }
                let parsed = MIMEParser.parse(raw)
                var proposals = AppointmentFinder.invitations(parsed, mail: message)
                if proposals.isEmpty, let model, AppointmentFinder.mightContainAppointment(subject: message.subject, text: parsed.readableText) {
                    proposals = (try? await AppointmentFinder.extract(text: parsed.readableText, mail: message, provider: model.provider, model: model.model)) ?? []
                }
                scanned.insert(message.id)
                found += proposals
            }
        }
        for proposal in found { proposed.insert(proposal.id) }
        persist(known: scanned.union(notified).union(messages.map(\.id)))
        return found.sorted { $0.start < $1.start }
    }
}

/// Is the user free for a proposal? Read live from EventKit.
enum AppointmentCheck {
    enum Status: Equatable {
        case free
        case conflict([String])
        case alreadyInCalendar
        case unknown

        var text: String {
            switch self {
            case .free: "you're free"
            case .conflict(let titles): "conflicts with " + titles.prefix(2).joined(separator: ", ")
            case .alreadyInCalendar: "already in your calendar"
            case .unknown: "no calendar access"
            }
        }
    }

    static func status(of proposal: AppointmentProposal) async -> Status {
        guard EventKitStore.eventsAuthorized,
            let events = try? await EventKitStore.shared.events(from: proposal.start.addingTimeInterval(-60), to: proposal.end.addingTimeInterval(60))
        else { return .unknown }
        let same = events.first { event in
            abs(event.start.timeIntervalSince(proposal.start)) < 5 * 60
                && (event.title.localizedCaseInsensitiveContains(proposal.title) || proposal.title.localizedCaseInsensitiveContains(event.title)
                    || proposal.origin == .invitation)
        }
        if same != nil { return .alreadyInCalendar }
        let overlapping = events.filter { $0.blocksTime && $0.start < proposal.end && $0.end > proposal.start }
        if proposal.isAllDay || overlapping.isEmpty { return .free }
        return .conflict(overlapping.map { "\($0.title) \(ToolDate.time($0.start))–\(ToolDate.time($0.end))" })
    }

    static func when(_ proposal: AppointmentProposal) -> String {
        let day = proposal.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return proposal.isAllDay ? "\(day), all day" : "\(day), \(ToolDate.time(proposal.start))–\(ToolDate.time(proposal.end))"
    }
}
