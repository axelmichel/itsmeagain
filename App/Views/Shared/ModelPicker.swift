import SwiftUI

/// Picks a provider + model from every enabled provider, grouped by provider.
struct ModelPicker: View {
    var title = "Model"
    @Binding var selection: ModelRef
    @Environment(AppModel.self) private var app

    var body: some View {
        Picker(title, selection: $selection) {
            if !app.isAvailable(selection) {
                Text("\(selection.model) — \(app.displayName(for: selection.provider)) (unavailable)").tag(selection)
            }
            ForEach(app.enabledProviders) { config in
                if let models = app.models[config.id], !models.isEmpty {
                    Section(config.name) {
                        ForEach(models) { model in
                            Text(label(for: model.displayName, details: model.details))
                                .tag(ModelRef(provider: config.id, model: model.id))
                        }
                    }
                }
            }
        }
    }

    private func label(for name: String, details: String?) -> String {
        details.map { "\(name)  —  \($0)" } ?? name
    }
}
