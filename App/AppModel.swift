import CompanionCore
import Foundation
import Observation
import Providers

/// App-wide state: provider configuration, the available models, and the chat engine.
@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let ollamaHost = "ollamaHost"
        static let defaultModel = "defaultModel"
    }

    var ollamaHost: String {
        didSet { UserDefaults.standard.set(ollamaHost, forKey: Keys.ollamaHost) }
    }

    var defaultModel: String {
        didSet { UserDefaults.standard.set(defaultModel, forKey: Keys.defaultModel) }
    }

    private(set) var models: [ModelInfo] = []
    private(set) var modelsError: String?
    private(set) var isLoadingModels = false

    let chat = ChatController()

    init(defaults: UserDefaults = .standard) {
        ollamaHost = defaults.string(forKey: Keys.ollamaHost) ?? OllamaProvider.defaultBaseURL.absoluteString
        defaultModel = defaults.string(forKey: Keys.defaultModel) ?? "gemma4:26b"
    }

    var ollama: OllamaProvider {
        OllamaProvider(baseURL: URL(string: ollamaHost) ?? OllamaProvider.defaultBaseURL)
    }

    func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await ollama.listModels()
            modelsError = nil
        } catch {
            models = []
            modelsError = error.localizedDescription
        }
    }
}
