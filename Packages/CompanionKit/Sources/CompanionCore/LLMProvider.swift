import Foundation

public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let ollama = ProviderID("ollama")
    public static let anthropic = ProviderID("anthropic")
    public static let appleIntelligence = ProviderID("apple-intelligence")
    public static let appleTranslation = ProviderID("apple-translation")
}

public struct ProviderCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let streaming = ProviderCapabilities(rawValue: 1 << 0)
    public static let tools = ProviderCapabilities(rawValue: 1 << 1)
    public static let vision = ProviderCapabilities(rawValue: 1 << 2)
    public static let embeddings = ProviderCapabilities(rawValue: 1 << 3)
    public static let thinking = ProviderCapabilities(rawValue: 1 << 4)
}

public struct ModelInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var sizeBytes: Int64?
    public var details: String?

    public init(id: String, displayName: String? = nil, sizeBytes: Int64? = nil, details: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
        self.sizeBytes = sizeBytes
        self.details = details
    }
}

/// A chat backend: Ollama, an OpenAI-compatible API, Anthropic, Apple on-device, …
public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }
    func listModels() async throws -> [ModelInfo]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

public protocol Embedder: Sendable {
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public enum ProviderError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case http(status: Int, message: String)
    case server(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .server(let message): message
        case .invalidResponse(let message): "Invalid response: \(message)"
        }
    }
}

/// One constrained-JSON completion without tools (classification, extraction).
///
/// Local models under a JSON-schema grammar sometimes run away in whitespace and never close the
/// object (seen with gemma4 when keys come in an unexpected order). Such streams are cut off early;
/// later attempts use plain JSON mode with the schema in the prompt, which measured reliable.
public enum StructuredCompletion {
    public static func json<Value: Decodable>(
        _ type: Value.Type,
        provider: any LLMProvider,
        model: String,
        system: String,
        user: String,
        schema: JSONValue,
        maxTokens: Int,
        contextLength: Int = 16_384,
        attempts: Int = 3
    ) async throws -> Value {
        var lastOutput = ""
        for attempt in 0..<max(attempts, 1) {
            let constrained = attempt == 0
            let request = ChatRequest(
                model: model,
                system: constrained ? system : system + "\n\nAnswer with one JSON object only, following this JSON Schema:\n" + schema.jsonString,
                messages: [.user(user)],
                options: ChatOptions(
                    temperature: constrained ? 0 : 0.3, contextLength: contextLength, keepAlive: "10m", think: false, maxTokens: maxTokens
                ),
                responseFormat: constrained ? schema : "json"
            )
            var output = ""
            for try await event in provider.stream(request) {
                guard case .textDelta(let delta) = event else { continue }
                output += delta
                if isRunaway(output) { break }
            }
            if let value = try? JSONDecoder().decode(Value.self, from: Data(output.utf8)) { return value }
            lastOutput = output
        }
        throw ProviderError.invalidResponse("expected JSON, got \(lastOutput.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))")
    }

    /// Only whitespace for the last 64 characters: the model is stuck.
    static func isRunaway(_ output: String) -> Bool {
        guard output.count > 64 else { return false }
        return output.suffix(64).allSatisfy(\.isWhitespace)
    }
}
