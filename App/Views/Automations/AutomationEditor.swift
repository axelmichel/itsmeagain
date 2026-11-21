import Automation
import Commands
import Persistence
import SwiftData
import SwiftUI

/// Edit one automation: what runs, when, and its run history.
struct AutomationEditor: View {
    @Bindable var automation: Automation
    let onDelete: () -> Void
    let onOpenConversation: (UUID) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context

    private enum Kind: String, CaseIterable, Identifiable {
        case daily = "At a time", interval = "Every …", onWake = "After waking"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                field("Name") {
                    TextField("Name", text: $automation.name)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(Theme.field)
                }

                Toggle("Enabled", isOn: enabledBinding)
                    .toggleStyle(.switch)

                field("When") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("When", selection: kindBinding) {
                            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        triggerDetails
                        Text(Schedule.describe(automation.trigger))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                field("Steps") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $automation.command)
                            .font(.body.monospaced())
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 90, maxHeight: 180)
                            .padding(6)
                            .background(Theme.field)
                        Text("""
                            One step per line: a /command (built-in or your own) or a prompt. Steps run in order in the same \
                            Chat conversation on your local model; each waits for the one before. A failed step doesn't stop \
                            the rest. Lines starting with # are comments. Changes still need your approval.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let steps = AutomationSteps.parse(automation.command)
                        if steps.count > 1 {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("\(index + 1).")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                        Text(step).lineLimit(1)
                                        if let error = stepProblem(step) {
                                            Text(error).foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                            .font(.caption)
                        } else if let only = steps.first, let error = stepProblem(only) {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                Toggle("Notify me with the result", isOn: $automation.notify)

                HStack {
                    Button("Run Now") { app.scheduler?.runNow(automation) }
                        .disabled(app.scheduler?.runningAutomation == automation.id)
                    Spacer()
                    Button("Delete Automation", role: .destructive, action: onDelete)
                }

                history
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .onChange(of: automation.command) { try? context.save() }
    }

    /// An unknown /command, caught while typing rather than at 7:30 in the morning.
    private func stepProblem(_ step: String) -> String? {
        guard let input = CommandInput(step) else { return nil }
        return app.commands.registry.command(named: input.name) == nil ? "unknown command /\(input.name)" : nil
    }

    // MARK: Trigger

    @ViewBuilder
    private var triggerDetails: some View {
        switch automation.trigger {
        case .daily(let hour, let minute, let weekdays):
            HStack(spacing: 12) {
                DatePicker(
                    "Time",
                    selection: Binding(
                        get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now },
                        set: {
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                            automation.trigger = .daily(hour: parts.hour ?? hour, minute: parts.minute ?? minute, weekdays: weekdays)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 2) {
                    // Monday first.
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        let on = weekdays.contains(day)
                        Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                            var days = weekdays
                            if on { days.remove(day) } else { days.insert(day) }
                            automation.trigger = .daily(hour: hour, minute: minute, weekdays: days)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 26, height: 22)
                        .background(on ? Theme.selection : Theme.field)
                        .foregroundStyle(on ? .primary : .secondary)
                    }
                }
            }
        case .interval(let minutes):
            Stepper(value: Binding(get: { minutes }, set: { automation.trigger = .interval(minutes: $0) }), in: 5...1440, step: 5) {
                Text(Schedule.describe(.interval(minutes: minutes)))
            }
            .fixedSize()
        case .onWake:
            EmptyView()
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(
            get: {
                switch automation.trigger {
                case .daily: .daily
                case .interval: .interval
                case .onWake: .onWake
                }
            },
            set: { kind in
                switch kind {
                case .daily: automation.trigger = .daily(hour: 7, minute: 30, weekdays: AutomationTrigger.weekdaysOnly)
                case .interval: automation.trigger = .interval(minutes: 60)
                case .onWake: automation.trigger = .onWake
                }
            }
        )
    }

    /// Switching on starts the clock now (missed slots before that never run) and asks for notifications.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { automation.enabled },
            set: { enabled in
                automation.enabled = enabled
                if enabled {
                    automation.enabledAt = .now
                    Task { await app.notifier.requestPermission() }
                }
                try? context.save()
            }
        )
    }

    // MARK: History

    private var history: some View {
        field("Runs") {
            let runs = automation.orderedRuns.prefix(20)
            if runs.isEmpty {
                Text("Not run yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(runs)) { run in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(run.status))
                                .foregroundStyle(color(run.status))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !run.summary.isEmpty {
                                    Text(run.summary).font(.callout).lineLimit(3)
                                }
                            }
                            Spacer()
                            if let id = run.conversationID {
                                Button("Open") { onOpenConversation(id) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        }
                        .padding(8)
                        .background(Theme.field)
                    }
                }
            }
        }
    }

    private func icon(_ status: AutomationRun.Status) -> String {
        switch status {
        case .running: "hourglass"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .needsApproval: "hand.raised"
        case .skipped: "forward"
        }
    }

    private func color(_ status: AutomationRun.Status) -> Color {
        switch status {
        case .succeeded: .green
        case .failed: .orange
        case .needsApproval: Theme.accent
        default: .secondary
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
