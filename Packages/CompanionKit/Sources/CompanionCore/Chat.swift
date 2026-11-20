import Foundation

public enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

public struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String = UUID().uuidString, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ChatMessage: Codable, Sendable, Hashable {
    public var role: Role
    public var content: String
    /// Tool calls requested by the assistant in this message.
    public var toolCalls: [ToolCall]
    /// For `.tool` messages: the call this message answers.
    public var toolCallID: String?
    public var toolName: String?
    /// The provider's raw assistant content (e.g. Claude's signed thinking blocks), replayed verbatim
    /// by that provider inside a tool loop. Never persisted across turns.
    public var providerContent: JSONValue?

    public init(
        role: Role,
        content: String,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        providerContent: JSONValue? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.providerContent = providerContent
    }

    public static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
    public static func assistant(_ content: String) -> ChatMessage { .init(role: .assistant, content: content) }
}

/// A tool the model may call. `parameters` is a JSON Schema object.
public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ChatOptions: Sendable, Hashable {
    public var temperature: Double?
    public var contextLength: Int?
    /// How long the backend keeps the model loaded (Ollama `keep_alive`, e.g. "5m", "0").
    public var keepAlive: String?
    /// Enable/disable reasoning for models that support it; `nil` leaves the backend default.
    public var think: Bool?
    public var maxTokens: Int?

    public init(
        temperature: Double? = nil,
        contextLength: Int? = nil,
        keepAlive: String? = nil,
        think: Bool? = nil,
        maxTokens: Int? = nil
    ) {
        self.temperature = temperature
        self.contextLength = contextLength
        self.keepAlive = keepAlive
        self.think = think
        self.maxTokens = maxTokens
    }
}

public struct ChatRequest: Sendable, Hashable {
    public var model: String
    public var system: String?
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var options: ChatOptions
    /// JSON Schema the reply must follow, for backends that support constrained output.
    public var responseFormat: JSONValue?
    /// Set for translation turns; dedicated translation backends read it instead of the prompt.
    public var targetLanguage: String?

    public init(
        model: String,
        system: String? = nil,
        messages: [ChatMessage],
        tools: [ToolSpec] = [],
        options: ChatOptions = .init(),
        responseFormat: JSONValue? = nil,
        targetLanguage: String? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.tools = tools
        self.options = options
        self.responseFormat = responseFormat
        self.targetLanguage = targetLanguage
    }
}

public struct Usage: Sendable, Hashable {
    public var promptTokens: Int?
    public var completionTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum ChatEvent: Sendable, Hashable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolCall(ToolCall)
    /// The complete assistant message in the provider's own format, for `ChatMessage.providerContent`.
    case assistantContent(JSONValue)
    case done(Usage?)
}
