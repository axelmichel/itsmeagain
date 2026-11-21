import CompanionCore
import Foundation

/// A local MCP server started as a program; newline-delimited JSON-RPC over stdin/stdout.
public actor StdioTransport: MCPTransport {
    private let executable: URL
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]
    private let timeout: Duration
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var buffer = Data()
    private var stderrTail = ""

    /// `command` is looked up on the PATH (with the usual Homebrew and npm locations added).
    public init(command: String, arguments: [String], environment: [String: String] = [:], timeout: Duration = .seconds(60)) {
        self.executable = Self.locate(command)
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }

    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.npm-global/bin"]

    static func locate(_ command: String) -> URL {
        if command.hasPrefix("/") || command.hasPrefix("~") { return URL(filePath: (command as NSString).expandingTildeInPath) }
        for directory in searchPath where FileManager.default.isExecutableFile(atPath: directory + "/" + command) {
            return URL(filePath: directory + "/" + command)
        }
        return URL(filePath: "/usr/bin/env")
    }

    private func start() throws {
        guard process == nil || process?.isRunning == false else { return }
        let process = Process()
        process.executableURL = executable
        // Not found in the usual places: let env find it on the PATH.
        process.arguments = executable.path == "/usr/bin/env" ? [command] + arguments : arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (Self.searchPath + [env["PATH"] ?? ""]).joined(separator: ":")
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.received(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            Task { await self.noteError(String(decoding: data, as: UTF8.self)) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.ended() }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
    }

    private func noteError(_ text: String) {
        stderrTail = String((stderrTail + text).suffix(600))
    }

    private func ended() {
        let message = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        for (_, continuation) in waiting {
            continuation.resume(throwing: MCPError.transport("The MCP server stopped" + (message.isEmpty ? "." : ": \(message)")))
        }
        waiting.removeAll()
        process = nil
        input = nil
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            // Responses have an id; server requests/notifications (logging, progress) are ignored.
            guard message["method"] == nil, let id = message["id"]?.intValue, let continuation = waiting.removeValue(forKey: id) else { continue }
            do { continuation.resume(returning: try JSONRPC.result(message)) } catch { continuation.resume(throwing: error) }
        }
    }

    private func write(_ value: JSONValue) throws {
        try start()
        var data = try JSONRPC.encode(value)
        data.append(0x0A)
        try input?.write(contentsOf: data)
    }

    public func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        try write(JSONRPC.request(id: id, method: method, params: params))
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.expire(id, method)
            }
        }
    }

    private func expire(_ id: Int, _ method: String) {
        waiting.removeValue(forKey: id)?.resume(throwing: MCPError.timeout(method))
    }

    public func notify(_ method: String, params: JSONValue?) async throws {
        try write(JSONRPC.notification(method: method, params: params))
    }

    public func close() async {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}

/// A remote MCP server over Streamable HTTP: POST each message; the answer is JSON or an SSE stream.
public actor HTTPTransport: MCPTransport {
    private let endpoint: URL
    private let headers: [String: String]
    private let session: URLSession
    private var sessionID: String?
    private var nextID = 1

    public init(endpoint: URL, headers: [String: String] = [:], session: URLSession = .shared) {
        self.endpoint = endpoint
        self.headers = headers
        self.session = session
    }

    private func post(_ body: JSONValue) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONRPC.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.transport("No HTTP response.") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = id }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401, 403:
            throw MCPError.transport("The server needs a sign-in (HTTP \(http.statusCode)). Servers with a browser sign-in (OAuth) aren't supported yet; a fixed token header works.")
        default: throw MCPError.transport("The MCP server answered HTTP \(http.statusCode).")
        }
    }

    public func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let (data, response) = try await post(JSONRPC.request(id: id, method: method, params: params))
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let messages: [JSONValue] = type.contains("text/event-stream")
            ? Self.events(data).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            : [try JSONDecoder().decode(JSONValue.self, from: data)]
        guard let reply = messages.first(where: { $0["id"]?.intValue == id }) else {
            throw MCPError.transport("The MCP server sent no answer to \(method).")
        }
        return try JSONRPC.result(reply)
    }

    public func notify(_ method: String, params: JSONValue?) async throws {
        _ = try await post(JSONRPC.notification(method: method, params: params))
    }

    public func close() async {
        sessionID = nil
    }

    /// The `data:` payloads of an SSE stream (multi-line data joined).
    static func events(_ data: Data) -> [String] {
        var events: [String] = []
        var current: [String] = []
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if line.isEmpty {
                if !current.isEmpty { events.append(current.joined(separator: "\n")); current = [] }
            } else if line.hasPrefix("data:") {
                current.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !current.isEmpty { events.append(current.joined(separator: "\n")) }
        return events
    }
}
