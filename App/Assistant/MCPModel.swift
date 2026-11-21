import CompanionCore
import Foundation
import MCP
import Observation
import Tools

/// MCP servers: settings in UserDefaults, secret header values in the Keychain, one client per
/// server (stdio processes start on first use and stay up while the app runs).
@MainActor
@Observable
final class MCPModel {
    private(set) var servers: [MCPServerConfig] = UserDefaults.standard.data(forKey: "mcpServers")
        .flatMap { try? JSONDecoder().decode([MCPServerConfig].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: "mcpServers") }
    }
    private(set) var connecting: Set<UUID> = []
    @ObservationIgnored private var clients: [UUID: MCPClient] = [:]

    static func headerAccount(_ id: UUID, _ header: String) -> String { "mcp.\(id.uuidString).\(header)" }

    func client(for server: MCPServerConfig) -> MCPClient? {
        if let existing = clients[server.id] { return existing }
        let transport: any MCPTransport
        switch server.kind {
        case .stdio:
            guard !server.command.isEmpty else { return nil }
            transport = StdioTransport(command: server.command, arguments: server.arguments, environment: server.environment)
        case .http:
            guard let url = URL(string: server.url), url.scheme == "https" || url.host() == "localhost" || url.host() == "127.0.0.1" else { return nil }
            var headers: [String: String] = [:]
            for name in server.secretHeaders {
                if let value = KeychainStore.key(for: Self.headerAccount(server.id, name)) { headers[name] = value }
            }
            transport = HTTPTransport(endpoint: url, headers: headers)
        }
        let client = MCPClient(transport: transport)
        clients[server.id] = client
        return client
    }

    /// Tools of enabled servers, as the model sees them (strict unless marked read-only).
    var tools: [any Tool] {
        servers.filter(\.enabled).flatMap { server -> [any Tool] in
            guard let client = client(for: server) else { return [] }
            return server.tools.filter(\.enabled).map { MCPTool(server: server.name, info: $0, remote: server.kind == .http, client: client) }
        }
    }

    // MARK: Editing

    func add(_ server: MCPServerConfig, secrets: [String: String] = [:]) {
        for (name, value) in secrets where !value.isEmpty { KeychainStore.setKey(value, for: Self.headerAccount(server.id, name)) }
        servers.append(server)
        Task { await connect(server.id) }
    }

    func update(_ server: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let changedTransport = servers[index].kind != server.kind || servers[index].command != server.command
            || servers[index].arguments != server.arguments || servers[index].url != server.url
        servers[index] = server
        if changedTransport { drop(server.id) }
    }

    func setTool(_ name: String, of id: UUID, enabled: Bool? = nil, readOnly: Bool? = nil) {
        guard let index = servers.firstIndex(where: { $0.id == id }), let tool = servers[index].tools.firstIndex(where: { $0.name == name }) else { return }
        if let enabled { servers[index].tools[tool].enabled = enabled }
        if let readOnly { servers[index].tools[tool].readOnly = readOnly }
    }

    func remove(_ id: UUID) {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        for name in server.secretHeaders { KeychainStore.setKey("", for: Self.headerAccount(id, name)) }
        drop(id)
        servers.removeAll { $0.id == id }
    }

    private func drop(_ id: UUID) {
        if let client = clients.removeValue(forKey: id) { Task { await client.close() } }
    }

    /// Connects and lists the tools; the user's choices per tool are kept across refreshes.
    func connect(_ id: UUID) async {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        drop(id)
        guard let client = client(for: server) else {
            setError(id, server.kind == .http ? "The address must start with https://." : "No command set.")
            return
        }
        connecting.insert(id)
        defer { connecting.remove(id) }
        do {
            let listed = try await client.listTools()
            guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
            let previous = Dictionary(uniqueKeysWithValues: servers[index].tools.map { ($0.name, $0) })
            servers[index].tools = listed.map { tool in
                var tool = tool
                if let old = previous[tool.name] {
                    tool.enabled = old.enabled
                    tool.readOnly = old.readOnly
                }
                return tool
            }
            servers[index].lastError = nil
        } catch {
            setError(id, error.localizedDescription)
            drop(id)
        }
    }

    private func setError(_ id: UUID, _ message: String) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].lastError = message
    }

    /// For /mcp.
    var markdown: String {
        guard !servers.isEmpty else { return "No MCP servers yet. Add one in Settings → Assistant → MCP servers." }
        return servers.map { server in
            let enabled = server.tools.filter(\.enabled)
            let readOnly = enabled.filter(\.readOnly).count
            var line = "**\(server.name)** (\(server.kind == .stdio ? "local" : "remote"))\(server.enabled ? "" : " · off") — "
                + "\(enabled.count) of \(server.tools.count) tools on, \(readOnly) without asking"
            if let error = server.lastError { line += "\n  _\(error)_" }
            return line
        }.joined(separator: "\n")
    }
}
