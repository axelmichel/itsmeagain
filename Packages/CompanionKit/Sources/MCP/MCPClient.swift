import CompanionCore
import Foundation

/// A configured MCP server: a local program (stdio) or a remote endpoint (Streamable HTTP).
public struct MCPServerConfig: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case stdio, http }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// stdio: the program and its arguments.
    public var command: String
    public var arguments: [String]
    /// stdio: extra environment variables (non-secret).
    public var environment: [String: String]
    /// http: the endpoint.
    public var url: String
    /// http: header names whose values are kept in the Keychain (e.g. "Authorization").
    public var secretHeaders: [String]
    public var enabled: Bool
    /// Tools as last listed, with the user's choices per tool.
    public var tools: [MCPToolInfo]
    public var lastError: String?

    public init(
        id: UUID = UUID(), name: String, kind: Kind, command: String = "", arguments: [String] = [], environment: [String: String] = [:],
        url: String = "", secretHeaders: [String] = [], enabled: Bool = true, tools: [MCPToolInfo] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.url = url
        self.secretHeaders = secretHeaders
        self.enabled = enabled
        self.tools = tools
    }
}

public struct MCPToolInfo: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var enabled: Bool
    /// Marked by the user as only reading: runs without asking. Default: every call needs approval.
    public var readOnly: Bool

    public var id: String { name }

    public init(name: String, description: String, inputSchema: JSONValue, enabled: Bool = true, readOnly: Bool = false) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.enabled = enabled
        self.readOnly = readOnly
    }
}

public enum MCPError: LocalizedError, Equatable {
    case server(String, code: Int)
    case transport(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .server(let message, let code): "The MCP server answered with an error (\(code)): \(message)"
        case .transport(let message): message
        case .timeout(let what): "The MCP server didn't answer in time (\(what))."
        }
    }
}

/// Sends JSON-RPC requests and notifications; returns the `result`.
public protocol MCPTransport: Sendable {
    func request(_ method: String, params: JSONValue?) async throws -> JSONValue
    func notify(_ method: String, params: JSONValue?) async throws
    func close() async
}

/// The client side of MCP: initialize, list tools, call tools.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"
    let transport: any MCPTransport
    private var initialized = false
    public private(set) var serverName: String?

    public init(transport: any MCPTransport) {
        self.transport = transport
    }

    public func initialize() async throws {
        guard !initialized else { return }
        let result = try await transport.request("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": [:],
            "clientInfo": ["name": "ItsMeAgain", "version": "1.0"],
        ])
        serverName = result["serverInfo"]?["name"]?.stringValue
        try await transport.notify("notifications/initialized", params: nil)
        initialized = true
    }

    public func listTools() async throws -> [MCPToolInfo] {
        try await initialize()
        var tools: [MCPToolInfo] = []
        var cursor: String?
        repeat {
            let result = try await transport.request("tools/list", params: cursor.map { ["cursor": .string($0)] })
            guard case .array(let list)? = result["tools"] else { break }
            tools += list.compactMap { tool in
                guard let name = tool["name"]?.stringValue else { return nil }
                return MCPToolInfo(
                    name: name, description: tool["description"]?.stringValue ?? "",
                    inputSchema: tool["inputSchema"] ?? ["type": "object", "properties": [:]],
                    // A server's own hint that the tool only reads is shown, but the default stays "ask".
                    readOnly: false
                )
            }
            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil && tools.count < 500
        return tools
    }

    /// Calls a tool; text content is joined, other content types are named.
    public func callTool(_ name: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        try await initialize()
        let result = try await transport.request("tools/call", params: ["name": .string(name), "arguments": arguments])
        var parts: [String] = []
        if case .array(let content)? = result["content"] {
            for item in content {
                switch item["type"]?.stringValue {
                case "text": parts.append(item["text"]?.stringValue ?? "")
                case "resource": parts.append(item["resource"]?["text"]?.stringValue ?? "[resource \(item["resource"]?["uri"]?.stringValue ?? "")]")
                case let other?: parts.append("[\(other) content]")
                case nil: break
                }
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"] { parts.append(structured.jsonString) }
        return (parts.joined(separator: "\n"), result["isError"] == .bool(true))
    }

    public func close() async {
        await transport.close()
    }
}

// MARK: JSON-RPC helpers

enum JSONRPC {
    static func request(id: Int, method: String, params: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func notification(method: String, params: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { object["params"] = params }
        return .object(object)
    }

    /// The `result` of a response, or the error it carries.
    static func result(_ response: JSONValue) throws -> JSONValue {
        if let error = response["error"] {
            throw MCPError.server(error["message"]?.stringValue ?? "unknown error", code: error["code"]?.intValue ?? 0)
        }
        return response["result"] ?? .object([:])
    }

    static func encode(_ value: JSONValue) throws -> Data {
        try JSONEncoder().encode(value)
    }
}
