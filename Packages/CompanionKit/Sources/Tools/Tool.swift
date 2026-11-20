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

/// A function the model can call. Errors thrown by `run` are reported back to the model as text.
public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    func run(_ arguments: JSONValue) async throws -> ToolOutput
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
