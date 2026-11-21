import CompanionCore
import Foundation
import Tools

/// One tool of an MCP server, as the model sees it. Strict by default: private (local models only),
/// a write (approval on every call) unless the user marked it read-only. Tools of remote servers count
/// as sending data out, so they're locked once private data was read in the same turn; local servers
/// don't (else a two-step task like "list a folder, then read a file" could never work). Results are
/// untrusted text.
public struct MCPTool: Tool {
    public let server: String
    public let info: MCPToolInfo
    public let remote: Bool
    let client: MCPClient

    public init(server: String, info: MCPToolInfo, remote: Bool, client: MCPClient) {
        self.server = server
        self.info = info
        self.remote = remote
        self.client = client
    }

    /// "mcp_<server>_<tool>", within the 64 characters model APIs allow.
    public static func modelName(server: String, tool: String) -> String {
        func clean(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: #"[^a-z0-9_]+"#, with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        }
        return String("mcp_\(clean(server))_\(clean(tool))".prefix(64))
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: Self.modelName(server: server, tool: info.name),
            description: "[\(server)] " + (info.description.isEmpty ? info.name : String(info.description.prefix(1_000))),
            parameters: info.inputSchema
        )
    }

    public var dataClass: ToolDataClass { .private }
    public var effect: ToolEffect { info.readOnly ? .read : .write }
    public var sendsDataExternally: Bool { remote }

    public func describe(_ arguments: JSONValue) -> String {
        "\(server): \(info.name) \(arguments.jsonString.prefix(200))"
    }

    public func run(_ arguments: JSONValue) async throws -> ToolOutput {
        let (text, isError) = try await client.callTool(info.name, arguments: arguments)
        let trimmed = text.count > 12_000 ? String(text.prefix(12_000)) + "\n[… truncated]" : text
        if isError { throw ToolError.failed("\(server) reported an error: \(trimmed.prefix(500))") }
        return ToolOutput(content: Untrusted.wrap(trimmed.isEmpty ? "(no content)" : trimmed, source: "mcp:\(server)"))
    }
}

/// Servers listed in Claude Code (`~/.claude.json`) and Claude Desktop configs, for import.
public enum MCPConfigImport {
    public struct Found: Sendable, Hashable {
        public var config: MCPServerConfig
        /// Header values or env entries that look secret and are left out.
        public var omittedSecrets: [String]
        /// e.g. "needs a browser sign-in (OAuth)".
        public var note: String?
    }

    public static func found(files: [URL] = [
        URL.homeDirectory.appending(path: ".claude.json"),
        URL.applicationSupportDirectory.appending(path: "Claude/claude_desktop_config.json"),
    ]) -> [Found] {
        var result: [Found] = []
        var names = Set<String>()
        for file in files {
            guard let data = try? Data(contentsOf: file), let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                case .object(let servers)? = json["mcpServers"]
            else { continue }
            for (name, entry) in servers.sorted(by: { $0.key < $1.key }) where names.insert(name).inserted {
                if let found = parse(name: name, entry) { result.append(found) }
            }
        }
        return result
    }

    static func parse(name: String, _ entry: JSONValue) -> Found? {
        if let command = entry["command"]?.stringValue {
            var arguments: [String] = []
            if case .array(let list)? = entry["args"] { arguments = list.compactMap(\.stringValue) }
            var environment: [String: String] = [:]
            var omitted: [String] = []
            if case .object(let env)? = entry["env"] {
                for (key, value) in env {
                    if key.range(of: #"(?i)token|key|secret|password"#, options: .regularExpression) != nil { omitted.append(key) } else { environment[key] = value.stringValue ?? "" }
                }
            }
            return Found(config: MCPServerConfig(name: name, kind: .stdio, command: command, arguments: arguments, environment: environment), omittedSecrets: omitted.sorted(), note: nil)
        }
        if let url = entry["url"]?.stringValue {
            var secretHeaders: [String] = []
            if case .object(let headers)? = entry["headers"] { secretHeaders = headers.keys.sorted() }
            return Found(
                config: MCPServerConfig(name: name, kind: .http, url: url, secretHeaders: secretHeaders),
                omittedSecrets: secretHeaders,
                note: secretHeaders.isEmpty ? "probably needs a browser sign-in (OAuth), which isn't supported yet" : nil
            )
        }
        return nil
    }
}
