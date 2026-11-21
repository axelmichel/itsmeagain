import AppKit
import Mail
import Persistence
import PersonalData
import SwiftData
import SwiftUI

/// Appointments found in mail: when, from whom, whether you're free; Add puts it in your calendar
/// (your own click, so no approval card), with Undo.
struct AppointmentListView: View {
    let message: StoredMessage
    let index: Int
    let items: [AppointmentProposal]
    @Environment(\.modelContext) private var context
    @State private var statuses: [String: AppointmentCheck.Status] = [:]
    @State private var busy: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var calendars: [CalendarInfo] = []
    /// The calendar new events go into; shared with the calendar card's form.
    @AppStorage("eventCalendarID") private var calendarID = ""

    private var chosen: CalendarInfo? {
        calendars.first { $0.id == calendarID } ?? calendars.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(items) { item in
                row(item)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .task(id: items.map(\.status)) { await refresh() }
        .task { calendars = await EventKitStore.shared.writableCalendars() }
    }

    private func row(_ item: AppointmentProposal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Text(item.start.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(item.start.formatted(.dateTime.day()))
                    .font(.title3.weight(.medium))
            }
            .frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .strikethrough(item.status == .ignored)
                    .foregroundStyle(item.status == .ignored ? .secondary : .primary)
                Text([AppointmentCheck.when(item), item.location].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("From \(item.sender):")
                    if let url = URL(string: item.mailURL) {
                        Link(item.subject, destination: url).lineLimit(1)
                    } else {
                        Text(item.subject).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                if let error = errors[item.id] {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else {
                    statusLine(item)
                }
            }
            Spacer(minLength: 8)
            actions(item)
                .font(.caption)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.field)
    }

    @ViewBuilder
    private func statusLine(_ item: AppointmentProposal) -> some View {
        switch item.status {
        case .added:
            Label("Added to \(item.calendarTitle ?? "your calendar")", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(Theme.accent)
        case .ignored:
            Text("Ignored").font(.caption).foregroundStyle(.secondary)
        case .pending:
            switch statuses[item.id] {
            case .free?: Label("You're free", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
            case .conflict?: Label(statuses[item.id]!.text.capitalizedFirst, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            case .alreadyInCalendar?: Label("Already in your calendar", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
            case .unknown?: Text("No calendar access to check").font(.caption).foregroundStyle(.secondary)
            case nil: ProgressView().controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func actions(_ item: AppointmentProposal) -> some View {
        if busy.contains(item.id) {
            ProgressView().controlSize(.mini)
        } else {
            switch item.status {
            case .pending:
                HStack(spacing: 10) {
                    // One click: the last used calendar. The menu: any other calendar.
                    Menu {
                        ForEach(calendars) { info in
                            Button {
                                calendarID = info.id
                                add(item, to: info.id)
                            } label: {
                                Label {
                                    Text(info.source.isEmpty ? info.title : "\(info.title) — \(info.source)")
                                } icon: {
                                    Image(systemName: "circle.fill").foregroundStyle(info.colorHex.flatMap(Color.init(hex:)) ?? Theme.accent)
                                }
                            }
                        }
                    } label: {
                        Text("Add to \(chosen?.title ?? "Calendar")").fontWeight(.semibold)
                    } primaryAction: {
                        add(item, to: chosen?.id)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(statuses[item.id] == .alreadyInCalendar)
                    .help("Click to add to \(chosen?.title ?? "your default calendar"); open the menu for another calendar")
                    Button("Ignore") { update(item) { $0.status = .ignored } }
                }
            case .added, .ignored:
                Button("Undo") { undo(item) }
            }
        }
    }

    // MARK: Actions

    private func add(_ item: AppointmentProposal, to calendarID: String?) {
        busy.insert(item.id)
        Task {
            do {
                let event = try await EventKitStore.shared.createEvent(
                    title: item.title, start: item.start, end: item.end, isAllDay: item.isAllDay, calendarID: calendarID, location: item.location
                )
                update(item) {
                    $0.status = .added
                    $0.eventID = event.id
                    $0.calendarTitle = event.calendar
                }
                errors[item.id] = nil
            } catch {
                errors[item.id] = error.localizedDescription
            }
            busy.remove(item.id)
        }
    }

    private func undo(_ item: AppointmentProposal) {
        guard item.status == .added, let eventID = item.eventID else {
            update(item) { $0.status = .pending }
            return
        }
        busy.insert(item.id)
        Task {
            do {
                try await EventKitStore.shared.deleteEvent(id: eventID)
                update(item) {
                    $0.status = .pending
                    $0.eventID = nil
                }
            } catch {
                errors[item.id] = error.localizedDescription
            }
            busy.remove(item.id)
        }
    }

    private func refresh() async {
        for item in items where item.status == .pending {
            statuses[item.id] = await AppointmentCheck.status(of: item)
        }
    }

    private func update(_ item: AppointmentProposal, _ change: (inout AppointmentProposal) -> Void) {
        var attachments = message.attachments
        guard attachments.indices.contains(index), case .appointments(var stored) = attachments[index],
            let position = stored.firstIndex(where: { $0.id == item.id })
        else { return }
        change(&stored[position])
        attachments[index] = .appointments(stored)
        message.attachments = attachments
        try? context.save()
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
