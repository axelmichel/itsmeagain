import SwiftUI

struct ModelPicker: View {
    var title = "Model"
    @Binding var selection: String
    @Environment(AppModel.self) private var app

    var body: some View {
        Picker(title, selection: $selection) {
            if !app.models.contains(where: { $0.id == selection }) {
                Text("\(selection) (not installed)").tag(selection)
            }
            ForEach(app.models) { model in
                if let details = model.details {
                    Text("\(model.displayName)  —  \(details)").tag(model.id)
                } else {
                    Text(model.displayName).tag(model.id)
                }
            }
        }
        .help(app.modelsError ?? "")
    }
}
