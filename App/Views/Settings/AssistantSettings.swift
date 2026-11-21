import AppKit
import PersonalData
import SwiftUI

/// What Chat (the personal assistant) may see and do.
struct AssistantSettings: View {
    @Environment(AppModel.self) private var app
    @State private var calendars: [CalendarInfo] = []
    @State private var lists: [CalendarInfo] = []
    @State private var eventsAuthorized = EventKitStore.eventsAuthorized
    @State private var remindersAuthorized = EventKitStore.remindersAuthorized

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                LabeledContent("Calendars") { status(eventsAuthorized, denied: EventKitStore.eventsDenied) }
                LabeledContent("Reminders") { status(remindersAuthorized, denied: EventKitStore.remindersDenied) }
                if !eventsAuthorized || !remindersAuthorized {
                    HStack {
                        Button("Allow Access…") {
                            Task {
                                _ = await EventKitStore.shared.requestAccess()
                                await reload()
                            }
                        }
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                }
            } header: {
                Text("Access")
            } footer: {
                Text("Used only by Chat, which always runs on a local model. Events and reminders never leave this Mac.")
                    .foregroundStyle(.secondary)
            }

            if eventsAuthorized && !calendars.isEmpty {
                Section("Visible Calendars") {
                    ForEach(calendars) { visibilityToggle($0) }
                }
            }
            if remindersAuthorized && !lists.isEmpty {
                Section("Visible Reminder Lists") {
                    ForEach(lists) { visibilityToggle($0) }
                }
            }

            Section {
                Toggle("Create reminders without asking", isOn: $app.remindersWithoutAsking)
            } header: {
                Text("Approvals")
            } footer: {
                Text("Creating or moving events and completing reminders always asks first.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
        .task { await reload() }
    }

    private func status(_ authorized: Bool, denied: Bool) -> some View {
        Group {
            if authorized {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if denied {
                Text("Denied — allow in System Settings → Privacy & Security").foregroundStyle(.orange)
            } else {
                Text("Not yet allowed").foregroundStyle(.secondary)
            }
        }
    }

    private func visibilityToggle(_ calendar: CalendarInfo) -> some View {
        Toggle(isOn: Binding(
            get: { !app.hiddenCalendars.contains(calendar.id) },
            set: { visible in
                if visible { app.hiddenCalendars.remove(calendar.id) } else { app.hiddenCalendars.insert(calendar.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(calendar.title)
                Text(calendar.source + (calendar.allowsWrites ? "" : " · read-only"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        eventsAuthorized = EventKitStore.eventsAuthorized
        remindersAuthorized = EventKitStore.remindersAuthorized
        calendars = await EventKitStore.shared.calendars()
        lists = await EventKitStore.shared.reminderLists()
    }
}
