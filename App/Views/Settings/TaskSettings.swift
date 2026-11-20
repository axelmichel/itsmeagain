import Routing
import SwiftUI

/// Maps each task to a model and configures how it is prompted.
struct TaskSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selected: TaskKind = .chat

    private static let contextLengths = [4_096, 8_192, 16_384, 32_768, 65_536, 131_072]

    var body: some View {
        @Bindable var app = app
        let profile = $app.taskProfiles[selected]

        VStack(spacing: 0) {
            Picker("Task", selection: $selected) {
                ForEach(TaskKind.allCases) { task in
                    Label(task.title, systemImage: task.systemImage).tag(task)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])

            Form {
                Section {
                    ModelPicker(selection: Binding(
                        get: { ModelRef(provider: profile.wrappedValue.providerID, model: profile.wrappedValue.modelID) },
                        set: {
                            profile.wrappedValue.providerID = $0.provider
                            profile.wrappedValue.modelID = $0.model
                        }
                    ))
                    Picker("Thinking", selection: profile.think) {
                        Text("Model Default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    Picker("Context Window", selection: profile.contextLength) {
                        Text("Model Default").tag(Int?.none)
                        ForEach(Self.contextLengths, id: \.self) { length in
                            Text("\(length / 1024)K tokens").tag(Int?.some(length))
                        }
                    }
                    Toggle("Custom Temperature", isOn: Binding(
                        get: { profile.wrappedValue.temperature != nil },
                        set: { profile.wrappedValue.temperature = $0 ? 0.7 : nil }
                    ))
                    if let temperature = profile.wrappedValue.temperature {
                        LabeledContent("Temperature") {
                            HStack {
                                Slider(
                                    value: Binding(get: { temperature }, set: { profile.wrappedValue.temperature = $0 }),
                                    in: 0...2,
                                    step: 0.1
                                )
                                Text(temperature, format: .number.precision(.fractionLength(1)))
                                    .monospacedDigit()
                                    .frame(width: 30)
                            }
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    if let note = providerNote(for: profile.wrappedValue) {
                        Text(note).foregroundStyle(.secondary)
                    }
                }

                Section("Behaviour") {
                    if selected == .translate {
                        Picker("Default Target Language", selection: $app.defaultTargetLanguage) {
                            ForEach(Languages.common, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Toggle("Send Conversation History", isOn: profile.includesHistory)
                }

                Section {
                    TextEditor(text: profile.systemPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 110)
                } header: {
                    Text("System Prompt")
                } footer: {
                    if selected == .translate {
                        Text("\(TaskProfile.targetLanguagePlaceholder) is replaced with the target language.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Reset \(selected.title) to Defaults") {
                        app.taskProfiles[selected] = TaskProfiles.defaults[selected]
                    }
                    .disabled(app.taskProfiles[selected] == TaskProfiles.defaults[selected])
                }
            }
            .formStyle(.grouped)
        }
        .frame(height: 620)
    }

    private func providerNote(for profile: TaskProfile) -> String? {
        switch app.config(for: profile.providerID)?.kind {
        case .anthropic?:
            "Claude ignores temperature and context window; “Thinking: Off” lowers effort instead."
        case .appleIntelligence?:
            "The on-device model has a 4K-token context; long conversations are condensed."
        case .appleTranslation?:
            "Apple Translation only translates the latest message; prompt and options are ignored."
        default:
            nil
        }
    }
}
