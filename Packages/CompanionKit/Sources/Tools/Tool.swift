import CompanionCore
import Foundation

/// A web page or document a tool looked at, shown to the user as a source.
public struct SourceRef: Codable, Sendable, Hashable {
    public var title: String
    public var url: String
    public var snippet: String?

    public init(title: String, url: String, snippet: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public struct ToolOutput: Sendable, Hashable {
    /// What the model reads.
    public var content: String
    public var sources: [SourceRef]

    public init(content: String, sources: [SourceRef] = []) {
        self.content = content
        self.sources = sources
    }
}

/// Whether a tool exposes the user's private data. Private tools are only offered to local models.
public enum ToolDataClass: Sendable, Hashable {
    case `public`
    case `private`
}

/// Whether a tool only reads or also changes something. Writes need the user's approval.
public enum ToolEffect: Sendable, Hashable {
    case read
    case write
}

/// A function the model can call. Errors thrown by `run` are reported back to the model as text.
public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    var dataClass: ToolDataClass { get }
    var effect: ToolEffect { get }
    /// True when the model's arguments leave the machine (search queries, URLs). Such tools are
    /// locked for the rest of a turn once private data was read, so it can't be exfiltrated.
    var sendsDataExternally: Bool { get }
    func run(_ arguments: JSONValue) async throws -> ToolOutput
    /// What a write would do, in plain words, for the approval prompt.
    func describe(_ arguments: JSONValue) -> String
}

extension Tool {
    public var dataClass: ToolDataClass { .public }
    public var effect: ToolEffect { .read }
    public var sendsDataExternally: Bool { false }
    public func describe(_ arguments: JSONValue) -> String {
        "\(spec.name) \(arguments.jsonString)"
    }
}

/// A write the model wants to perform, waiting for the user.
public struct ApprovalRequest: Sendable, Hashable, Identifiable {
    /// The tool call ID.
    public var id: String
    public var toolName: String
    public var summary: String
    public var arguments: JSONValue

    public init(id: String, toolName: String, summary: String, arguments: JSONValue) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.arguments = arguments
    }
}

/// Enforced by `ToolLoop`, independent of what the model says.
public struct ToolPolicy: Sendable {
    /// Whether the provider runs locally (Ollama, Apple on-device). Private tools need this.
    public var providerIsLocal: Bool
    /// Write tools the user allowed without asking (narrow, user-configured).
    public var autoApproved: Set<String>
    public var approve: @Sendable (ApprovalRequest) async -> Bool

    public init(
        providerIsLocal: Bool,
        autoApproved: Set<String> = [],
        approve: @escaping @Sendable (ApprovalRequest) async -> Bool
    ) {
        self.providerIsLocal = providerIsLocal
        self.autoApproved = autoApproved
        self.approve = approve
    }

    /// Strictest default: treat the provider as remote and deny every write.
    public static let strict = ToolPolicy(providerIsLocal: false) { _ in false }
}

public enum ToolError: LocalizedError, Equatable {
    case missingArgument(String)
    case invalidArgument(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let name): "Missing required argument “\(name)”."
        case .invalidArgument(let message): message
        case .failed(let message): message
        }
    }
}

extension JSONValue {
    /// A required, non-empty string argument.
    public func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ToolError.missingArgument(key)
        }
        return value
    }
}

/// Marks text written by third parties (mail, news, web) so the model treats it as data.
/// The Chat system prompt explains the tag; the tool policy enforces what really matters.
public enum Untrusted {
    public static func wrap(_ text: String, source: String) -> String {
        // A closing tag inside the content must not end the block early.
        let safe = text.replacingOccurrences(of: "</untrusted>", with: "</untrusted_>")
        return "<untrusted source=\"\(source)\">\n\(safe)\n</untrusted>"
    }
}
