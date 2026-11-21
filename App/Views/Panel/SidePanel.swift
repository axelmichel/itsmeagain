import Obsidian
import Persistence
import PersonalData
import SwiftUI
import Weather

/// What can be hooked into the right panel — each a live view of a command.
enum PanelWidget: String, CaseIterable, Codable, Identifiable {
    case calendar, reminders, weather, news, tasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .weather: "Weather"
        case .news: "News"
        case .tasks: "Tasks from notes"
        }
    }

    var command: String {
        switch self {
        case .calendar: "/cal"
        case .reminders: "/reminders"
        case .weather: "/weather"
        case .news: "/news"
        case .tasks: "/todos due"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .weather: "cloud.sun"
        case .news: "newspaper"
        case .tasks: "checkmark.square"
        }
    }
}

/// The collapsible right panel: widgets you add with +, reorder and remove.
struct SidePanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Panel").font(.callout.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(PanelWidget.allCases.filter { !app.panelWidgets.contains($0) }) { widget in
                        Button("\(widget.title)  (\(widget.command))", systemImage: widget.symbol) { app.panelWidgets.append(widget) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(app.panelWidgets.count == PanelWidget.allCases.count)
                .help("Add a widget")
            }
            .padding(.horizontal, 12)
            .frame(height: ContentView.headerHeight)
            .background(Theme.header)
            .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if app.panelWidgets.isEmpty {
                        Text("Add widgets with + — calendar, reminders, weather, news, tasks.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.panelWidgets) { widget in
                        WidgetFrame(widget: widget) { content(widget) }
                    }
                }
                .padding(12)
            }
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private func content(_ widget: PanelWidget) -> some View {
        switch widget {
        case .calendar: CalendarCardView(message: nil, index: 0, style: .month, date: .now)
        case .reminders: PanelReminders()
        case .weather: PanelWeather()
        case .news: PanelNews()
        case .tasks: PanelTasks()
        }
    }
}

private struct WidgetFrame<Content: View>: View {
    let widget: PanelWidget
    @ViewBuilder let content: () -> Content
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: widget.symbol).foregroundStyle(.secondary)
                Text(widget.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Move Up") { move(-1) }.disabled(app.panelWidgets.first == widget)
                    Button("Move Down") { move(1) }.disabled(app.panelWidgets.last == widget)
                    Divider()
                    Button("Remove from Panel") { app.panelWidgets.removeAll { $0 == widget } }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            content()
        }
    }

    private func move(_ offset: Int) {
        guard let index = app.panelWidgets.firstIndex(of: widget) else { return }
        let target = index + offset
        guard app.panelWidgets.indices.contains(target) else { return }
        app.panelWidgets.swapAt(index, target)
    }
}

// MARK: Widgets

private struct PanelReminders: View {
    @State private var items: [ReminderItem] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if loaded && items.isEmpty {
                Text(EventKitStore.remindersAuthorized ? "Nothing due today." : "No access to Reminders.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button { toggle(item) } label: {
                        Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isCompleted ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).strikethrough(item.isCompleted).foregroundStyle(item.isCompleted ? .secondary : .primary).lineLimit(2)
                        if let due = item.due, item.dueHasTime || due < Calendar.current.startOfDay(for: .now) {
                            Text(due < Calendar.current.startOfDay(for: .now) ? "overdue" : due.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(due < .now && !item.isCompleted ? Color.orange : Color.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.field)
            }
        }
        .task {
            // Live: refreshed every minute while visible.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func load() async {
        guard EventKitStore.remindersAuthorized else { loaded = true; return }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
        let open = (try? await EventKitStore.shared.reminders(list: nil, includeCompleted: false)) ?? []
        let due = open.filter { ($0.due ?? .distantFuture) < end }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        // Ticked ones stay visible until the next refresh, so a mis-click can be undone.
        items = due + items.filter { $0.isCompleted && !due.contains($0) }
        loaded = true
    }

    private func toggle(_ item: ReminderItem) {
        Task {
            if let updated = try? await EventKitStore.shared.setReminderCompleted(id: item.id, !item.isCompleted) {
                items = items.map { $0.id == item.id ? updated : $0 }
            }
        }
    }
}

private struct PanelWeather: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let weather = app.weather
        Group {
            if weather.place == nil {
                Text("Choose your place in Settings → Assistant → Weather.").font(.callout).foregroundStyle(.secondary)
            } else if let report = weather.report {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: WeatherCode.symbol(report.code, isDay: report.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 30))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Int(report.temperature.rounded()))°").font(.title.weight(.medium))
                            Text(WeatherCode.text(report.code)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(report.place.name).font(.callout.weight(.medium))
                            Text("H \(Int(report.high.rounded()))° · L \(Int(report.low.rounded()))°").font(.caption).foregroundStyle(.secondary)
                            if report.precipitationChance >= 20 {
                                Text("Rain \(report.precipitationChance)%").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(Array(report.hours.prefix(6).enumerated()), id: \.offset) { _, hour in
                            VStack(spacing: 2) {
                                Text(hour.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)))).font(.caption2).foregroundStyle(.secondary)
                                Image(systemName: WeatherCode.symbol(hour.code)).symbolRenderingMode(.multicolor).font(.caption)
                                Text("\(Int(hour.temperature.rounded()))°").font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else if let error = weather.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.field)
        .task {
            while !Task.isCancelled {
                await weather.refresh()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }
}

private struct PanelNews: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let news = app.news
        let groups = news.ranking.digest(news.library.items, since: .now.addingTimeInterval(-24 * 3_600), perTopic: 2)
        VStack(alignment: .leading, spacing: 6) {
            if groups.isEmpty {
                Text("No matching news today.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.topic) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.topic).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.items) { item in
                        if let url = URL(string: item.link) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(item.source).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.field)
    }
}

private struct PanelTasks: View {
    @Environment(AppModel.self) private var app
    @State private var tasks: [VaultTask] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if loaded && tasks.isEmpty {
                Text(app.vaults.stores.isEmpty ? "No Obsidian vault enabled." : "No tasks due.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(tasks) { task in
                HStack(alignment: .top, spacing: 8) {
                    Button { toggle(task) } label: {
                        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.isDone ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    Text(task.text).strikethrough(task.isDone).foregroundStyle(task.isDone ? .secondary : .primary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.field)
            }
        }
        .task {
            while !Task.isCancelled {
                let stores = app.vaults.stores
                tasks = stores.flatMap { $0.tasks() }.filter { $0.isDue() }
                loaded = true
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func toggle(_ task: VaultTask) {
        guard let store = app.vaults.stores.first(where: { $0.vault.name == task.vault }),
            let updated = try? store.setDone(task, !task.isDone)
        else { return }
        tasks = tasks.map { $0.id == task.id ? updated : $0 }
    }
}
