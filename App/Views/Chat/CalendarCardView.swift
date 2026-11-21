import AppKit
import Persistence
import PersonalData
import SwiftData
import SwiftUI

/// A live calendar card in the transcript: a month grid with event dots, the selected day (or week)
/// as a timeline in calendar colours, and a form to add events. Events are read from EventKit each
/// time the card shows; only the selected day is stored. Adding is the user's own click, so no
/// approval card.
struct CalendarCardView: View {
    let message: StoredMessage
    let index: Int
    let style: CalendarCardStyle
    @Environment(\.modelContext) private var context
    @State private var selected: Date
    @State private var month: Date
    @State private var showsMonth: Bool
    @State private var monthEvents: [CalendarEvent] = []
    @State private var events: [CalendarEvent] = []
    @State private var loaded = false
    @State private var adding = false
    @State private var lastAdded: CalendarEvent?
    @State private var error: String?

    private let calendar = Calendar.current

    init(message: StoredMessage, index: Int, style: CalendarCardStyle, date: Date) {
        self.message = message
        self.index = index
        self.style = style
        let day = Calendar.current.startOfDay(for: date)
        _selected = State(initialValue: day)
        _month = State(initialValue: day)
        _showsMonth = State(initialValue: style == .month)
    }

    private var rangeEnd: Date {
        calendar.date(byAdding: .day, value: style == .week ? 7 : 1, to: selected)!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsMonth {
                Divider()
                MonthGridView(month: month, selected: selected, events: monthEvents) { day in
                    select(day)
                }
                .padding(10)
            }
            Divider()
            if style == .week {
                weekList
            } else {
                DayTimeline(events: events, loaded: loaded)
            }
            if let lastAdded {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
                    Text("Added “\(lastAdded.title)” · \(lastAdded.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                        .font(.caption)
                    Spacer()
                    Button("Undo") { undoAdd(lastAdded) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            if let error {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption)
                    Spacer()
                    if !EventKitStore.eventsAuthorized {
                        Button("Allow Access…", action: requestAccess)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(Theme.field)
        .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
        .frame(maxWidth: 460, alignment: .leading)
        .task(id: LoadKey(selected: selected, month: month, showsMonth: showsMonth)) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help(style == .week ? "Previous week" : "Previous day")
                Button("Today") { select(calendar.startOfDay(for: .now)) }
                    .font(.caption)
                    .disabled(calendar.isDateInToday(selected) && calendar.isDate(month, equalTo: .now, toGranularity: .month))
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .help(style == .week ? "Next week" : "Next day")
                Button { showsMonth.toggle() } label: {
                    Image(systemName: showsMonth ? "calendar.badge.minus" : "calendar")
                }
                .help(showsMonth ? "Hide the month" : "Show the month")
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("Add an event")
                    .popover(isPresented: $adding, arrowEdge: .bottom) {
                        AddEventForm(day: selected) { event in
                            lastAdded = event
                            adding = false
                            if !calendar.isDate(event.start, inSameDayAs: selected), style != .week { select(calendar.startOfDay(for: event.start)) }
                            Task { await load() }
                        }
                    }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var title: String {
        switch style {
        case .week:
            "\(selected.formatted(.dateTime.day().month(.abbreviated))) – \(calendar.date(byAdding: .day, value: 6, to: selected)!.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .day, .month:
            relativeName(selected) ?? selected.formatted(.dateTime.weekday(.wide))
        }
    }

    private var subtitle: String {
        switch style {
        case .week:
            "\(events.count) events"
        case .day, .month:
            (relativeName(selected) != nil ? selected.formatted(.dateTime.weekday(.wide)) + ", " : "")
                + selected.formatted(.dateTime.day().month(.wide).year())
                + " · week \(calendar.component(.weekOfYear, from: selected))"
        }
    }

    private func relativeName(_ day: Date) -> String? {
        calendar.isDateInToday(day) ? "Today" : calendar.isDateInTomorrow(day) ? "Tomorrow" : calendar.isDateInYesterday(day) ? "Yesterday" : nil
    }

    // MARK: Week

    private var weekList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: selected)!
                let dayEvents = events.filter { occurs($0, on: day) }
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.title3.weight(calendar.isDateInToday(day) ? .bold : .regular))
                            .foregroundStyle(calendar.isDateInToday(day) ? Theme.accent : .primary)
                    }
                    .frame(width: 36)
                    if dayEvents.isEmpty {
                        Text(loaded ? "—" : "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(dayEvents) { EventRow(event: $0, compact: true) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                if offset < 6 { Divider().padding(.leading, 56) }
            }
        }
    }

    // MARK: Actions

    private func select(_ day: Date) {
        selected = calendar.startOfDay(for: day)
        if !calendar.isDate(month, equalTo: selected, toGranularity: .month) { month = selected }
        store()
    }

    private func step(_ direction: Int) {
        select(calendar.date(byAdding: .day, value: direction * (style == .week ? 7 : 1), to: selected)!)
    }

    private func undoAdd(_ event: CalendarEvent) {
        Task {
            do {
                try await EventKitStore.shared.deleteEvent(id: event.id)
                lastAdded = nil
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func requestAccess() {
        Task {
            _ = await EventKitStore.shared.requestAccess()
            if !EventKitStore.eventsAuthorized, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            await load()
        }
    }

    private func load() async {
        guard EventKitStore.eventsAuthorized else {
            // Make "no access" unmistakable; an empty grid would look like an empty calendar.
            monthEvents = []
            events = []
            error = "ItsMeAgain has no access to your calendars right now, so nothing can be shown."
            return
        }
        do {
            let store = EventKitStore.shared
            events = try await store.events(from: selected, to: rangeEnd)
            if showsMonth {
                let grid = MonthGrid(containing: month)
                monthEvents = try await store.events(from: grid.interval.start, to: grid.interval.end)
            }
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func occurs(_ event: CalendarEvent, on day: Date) -> Bool {
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        return event.start < end && event.end > day || calendar.isDate(event.start, inSameDayAs: day)
    }

    private func store() {
        var attachments = message.attachments
        guard attachments.indices.contains(index) else { return }
        attachments[index] = .calendar(style: style, date: selected)
        message.attachments = attachments
        try? context.save()
    }

    private struct LoadKey: Hashable {
        var selected: Date
        var month: Date
        var showsMonth: Bool
    }
}

// MARK: Month grid

private struct MonthGridView: View {
    let month: Date
    let selected: Date
    let events: [CalendarEvent]
    let onSelect: (Date) -> Void
    @State private var shown: Date?

    private let calendar = Calendar.current
    private var displayed: Date { shown ?? month }

    var body: some View {
        let grid = MonthGrid(containing: displayed)
        VStack(spacing: 4) {
            HStack {
                Text(grid.month.formatted(.dateTime.month(.wide).year()))
                    .font(.callout.weight(.medium))
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous month")
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next month")
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 2)
            HStack(spacing: 0) {
                ForEach(Array(grid.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            DayCell(
                                day: day,
                                isSelected: calendar.isDate(day, inSameDayAs: selected),
                                colors: colors(on: day)
                            ) {
                                onSelect(day)
                            }
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 32)
                        }
                    }
                }
            }
        }
        // The card's month follows the selected day; arrows here browse without selecting.
        .onChange(of: month) { shown = nil }
    }

    private func shift(_ months: Int) {
        shown = calendar.date(byAdding: .month, value: months, to: displayed)
    }

    /// Up to three calendar colours of the day's events (only the shown month was loaded).
    private func colors(on day: Date) -> [Color] {
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        let hexes = events.filter { $0.start < end && $0.end > day && $0.participation != .declined }.map { $0.colorHex ?? "" }
        var seen: [String] = []
        for hex in hexes where !seen.contains(hex) { seen.append(hex) }
        return seen.prefix(3).map { Color(hex: $0) ?? Theme.accent }
    }
}

private struct DayCell: View {
    let day: Date
    let isSelected: Bool
    let colors: [Color]
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let today = Calendar.current.isDateInToday(day)
        Button(action: action) {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.day()))
                    .font(.callout.monospacedDigit().weight(today ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : today ? Theme.accent : .primary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isSelected ? Theme.accent : hovered ? Theme.hover : .clear))
                HStack(spacing: 2) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }
}

// MARK: Day

private struct DayTimeline: View {
    let events: [CalendarEvent]
    let loaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if events.isEmpty {
                Text(loaded ? "No events." : " ")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(events.filter(\.isAllDay)) { EventRow(event: $0, compact: false) }
            ForEach(events.filter { !$0.isAllDay }) { EventRow(event: $0, compact: false) }
        }
        .padding(10)
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let compact: Bool
    @State private var hovered = false

    private var color: Color { event.colorHex.flatMap(Color.init(hex:)) ?? Theme.accent }
    private var declined: Bool { event.participation == .declined }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                if event.isAllDay {
                    Text("all-day").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(ToolDate.time(event.start)).font(.caption.monospacedDigit())
                    if !compact {
                        Text(ToolDate.time(event.end)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 42, alignment: .trailing)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color.opacity(declined ? 0.35 : 1))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(compact ? .callout : .body)
                    .strikethrough(declined)
                    .foregroundStyle(declined ? .secondary : .primary)
                    .lineLimit(2)
                let details = [event.location, compact ? nil : event.calendar, event.participation == .pending ? "not answered" : nil]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 2 : 4)
        .padding(.horizontal, 4)
        .background(hovered ? Theme.hover : color.opacity(compact ? 0 : 0.08))
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AgendaFormatter.eventLine(event), forType: .string)
            }
            Button("Open Calendar") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
        }
    }
}

// MARK: Add

private struct AddEventForm: View {
    let onAdded: (CalendarEvent) -> Void
    @State private var title = ""
    @State private var start: Date
    @State private var allDay = false
    @State private var minutes = 60
    @State private var location = ""
    @State private var calendars: [CalendarInfo] = []
    @State private var calendarID: String?
    /// Last used calendar, shared with "Add to …" on appointments found in mail.
    @AppStorage("eventCalendarID") private var lastCalendarID = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private static let durations = [15, 30, 45, 60, 90, 120, 180, 240]

    init(day: Date, onAdded: @escaping (CalendarEvent) -> Void) {
        self.onAdded = onAdded
        let calendar = Calendar.current
        // Today: the next full hour; other days: 10:00.
        let start: Date
        if calendar.isDateInToday(day) {
            let next = calendar.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
            start = next
        } else {
            start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
        }
        _start = State(initialValue: start)
    }

    var body: some View {
        Form {
            TextField("Title", text: $title)
                .focused($titleFocused)
            DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            Toggle("All-day", isOn: $allDay)
            if !allDay {
                Picker("Duration", selection: $minutes) {
                    ForEach(Self.durations, id: \.self) { Text(Self.label($0)).tag($0) }
                }
            }
            TextField("Location", text: $location, prompt: Text("Optional"))
            if !calendars.isEmpty {
                Picker("Calendar", selection: $calendarID) {
                    ForEach(calendars) { info in
                        Label {
                            Text(info.source.isEmpty ? info.title : "\(info.title) — \(info.source)")
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(info.colorHex.flatMap(Color.init(hex:)) ?? Theme.accent)
                        }
                        .tag(Optional(info.id))
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Add Event", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .task {
            calendars = await EventKitStore.shared.writableCalendars()
            calendarID = calendarID ?? calendars.first { $0.id == lastCalendarID }?.id ?? calendars.first?.id
            titleFocused = true
        }
    }

    private static func label(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func save() {
        saving = true
        let calendar = Calendar.current
        let begin = allDay ? calendar.startOfDay(for: start) : start
        let end = allDay ? calendar.date(byAdding: .day, value: 1, to: begin)! : begin.addingTimeInterval(Double(minutes) * 60)
        let trimmedLocation = location.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let event = try await EventKitStore.shared.createEvent(
                    title: title.trimmingCharacters(in: .whitespaces), start: begin, end: end, isAllDay: allDay,
                    calendarID: calendarID, location: trimmedLocation.isEmpty ? nil : trimmedLocation
                )
                if let calendarID { lastCalendarID = calendarID }
                onAdded(event)
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

extension Color {
    /// "#RRGGBB"
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
