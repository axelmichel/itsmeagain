import Routing
import SwiftUI

/// Flat "Into <language>" menu for translation targets (matches the task and model menus).
struct LanguageMenu: View {
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(Languages.common, id: \.self) { language in
                Button {
                    selection = language
                } label: {
                    if language == selection {
                        Label(language, systemImage: "checkmark")
                    } else {
                        Text(language)
                    }
                }
            }
        } label: {
            Label("Into \(selection)", systemImage: "character.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Target language for translations")
    }
}
