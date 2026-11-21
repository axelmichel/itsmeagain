import Foundation
import Jira
import Observation

/// Connected Jira sites (read-only). Settings in UserDefaults, one token per site in the Keychain.
@MainActor
@Observable
final class JiraModel {
    private(set) var connections: [JiraConnection] = UserDefaults.standard.data(forKey: "jiraConnections")
        .flatMap { try? JSONDecoder().decode([JiraConnection].self, from: $0) } ?? [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(connections), forKey: "jiraConnections") }
    }
    private(set) var testing: Set<UUID> = []

    static func tokenAccount(_ id: UUID) -> String { "jira.\(id.uuidString)" }

    func hasToken(_ connection: JiraConnection) -> Bool {
        KeychainStore.key(for: Self.tokenAccount(connection.id)) != nil
    }

    /// Enabled sites with a token.
    var directory: JiraDirectory {
        JiraDirectory(clients: connections.filter(\.enabled).compactMap { connection in
            KeychainStore.key(for: Self.tokenAccount(connection.id)).map { JiraClient(connection: connection, token: $0) }
        })
    }

    var isConfigured: Bool { !directory.clients.isEmpty }

    func add(name: String, url: String, email: String, token: String) -> JiraConnection {
        let connection = JiraConnection(name: name.isEmpty ? (URL(string: url)?.host() ?? "Jira") : name, baseURL: url, email: email)
        KeychainStore.setKey(token, for: Self.tokenAccount(connection.id))
        connections.append(connection)
        return connection
    }

    func update(_ connection: JiraConnection, token: String?) {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[index] = connection
        if let token, !token.isEmpty { KeychainStore.setKey(token, for: Self.tokenAccount(connection.id)) }
    }

    func remove(_ id: UUID) {
        KeychainStore.setKey("", for: Self.tokenAccount(id))
        connections.removeAll { $0.id == id }
    }

    /// Detects Cloud / Data Center, checks the token (`myself`) and loads the project keys.
    @discardableResult
    func test(_ id: UUID) async -> String {
        guard var connection = connections.first(where: { $0.id == id }),
            let token = KeychainStore.key(for: Self.tokenAccount(id))
        else { return "No token saved." }
        testing.insert(id)
        defer { testing.remove(id) }
        var message: String
        do {
            connection.kind = try await JiraClient(connection: connection, token: token).detectKind()
            let client = JiraClient(connection: connection, token: token)
            let me = try await client.myself()
            connection.projectKeys = try await client.projectKeys()
            connection.lastError = nil
            message = "Connected as \(me) · \(connection.kind == .cloud ? "Cloud" : "Data Center") · \(connection.projectKeys.count) projects"
        } catch {
            connection.lastError = error.localizedDescription
            message = error.localizedDescription
        }
        connection.lastChecked = .now
        if let index = connections.firstIndex(where: { $0.id == id }) { connections[index] = connection }
        return message
    }
}
