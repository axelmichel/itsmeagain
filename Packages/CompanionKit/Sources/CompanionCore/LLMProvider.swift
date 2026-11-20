import Foundation

public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let ollama = ProviderID("ollama")
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
