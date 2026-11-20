import AppleIntelligence
import CompanionCore
import Foundation
import Providers

/// A configured backend. Persisted (without secrets) in UserDefaults; API keys are in the Keychain.
struct ProviderConfig: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case ollama, anthropic, openAICompatible, appleIntelligence, appleTranslation, claudeCode
    }

    var id: ProviderID
    var kind: Kind
    var name: String
    var baseURL: String
    var enabled = true

    var needsAPIKey: Bool { kind == .anthropic || kind == .openAICompatible }
    /// Built-ins can be disabled but not removed.
    var isBuiltIn: Bool { kind == .ollama || kind == .appleIntelligence || kind == .appleTranslation }
    var isLocal: Bool {
        switch kind {
        case .ollama, .appleIntelligence, .appleTranslation: true
        case .anthropic, .claudeCode: false
        case .openAICompatible: ["localhost", "127.0.0.1"].contains(URL(string: baseURL)?.host())
        }
    }

    var systemImage: String {
        switch kind {
        case .ollama: "server.rack"
        case .anthropic, .openAICompatible: isLocal ? "server.rack" : "cloud"
        case .appleIntelligence: "apple.intelligence"
        case .appleTranslation: "translate"
        case .claudeCode: "terminal"
        }
    }

    func makeProvider() -> any LLMProvider {
        let url = URL(string: baseURL)
        switch kind {
        case .ollama:
            return OllamaProvider(id: id, displayName: name, baseURL: url ?? OllamaProvider.defaultBaseURL)
        case .anthropic:
            return AnthropicProvider(
                id: id,
                displayName: name,
                apiKey: KeychainStore.key(for: id.rawValue) ?? "",
                baseURL: url ?? AnthropicProvider.defaultBaseURL
            )
        case .openAICompatible:
            return OpenAICompatibleProvider(
                id: id,
                displayName: name,
                baseURL: url ?? URL(string: "https://api.openai.com/v1")!,
                apiKey: KeychainStore.key(for: id.rawValue)
            )
        case .appleIntelligence:
            return AppleOnDeviceProvider()
        case .appleTranslation:
            return AppleTranslationProvider()
        case .claudeCode:
            return ClaudeCodeProvider(
                id: id,
                displayName: name,
                executable: ClaudeCodeProvider.locate(custom: baseURL),
                workingDirectory: AppData.claudeCodeWorkdir
            )
        }
    }

    static let builtIns: [ProviderConfig] = [
        ProviderConfig(id: .ollama, kind: .ollama, name: "Ollama", baseURL: OllamaProvider.defaultBaseURL.absoluteString),
        ProviderConfig(id: .appleIntelligence, kind: .appleIntelligence, name: "Apple Intelligence", baseURL: ""),
        ProviderConfig(id: .appleTranslation, kind: .appleTranslation, name: "Apple Translation", baseURL: ""),
    ]

    /// Templates offered by "Add Provider".
    struct Preset: Identifiable {
        var name: String
        var kind: Kind
        var baseURL: String
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Anthropic (Claude)", kind: .anthropic, baseURL: AnthropicProvider.defaultBaseURL.absoluteString),
        Preset(name: "Claude Code (your subscription)", kind: .claudeCode, baseURL: ""),
        Preset(name: "OpenAI (ChatGPT)", kind: .openAICompatible, baseURL: "https://api.openai.com/v1"),
        Preset(name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1"),
        Preset(name: "LM Studio", kind: .openAICompatible, baseURL: "http://localhost:1234/v1"),
        Preset(name: "Custom (OpenAI-compatible)", kind: .openAICompatible, baseURL: "https://"),
    ]
}

/// A provider + model pair, e.g. what a task is mapped to.
struct ModelRef: Hashable {
    var provider: ProviderID
    var model: String
}
