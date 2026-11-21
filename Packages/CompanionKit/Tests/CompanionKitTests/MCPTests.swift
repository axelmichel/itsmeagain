import CompanionCore
import Foundation
import Synchronization
import Testing

@testable import MCP
@testable import Tools

@Suite struct MCPTests {
    static let fakeServer = #"""
        import sys, json
        for line in sys.stdin:
            msg = json.loads(line)
            if "id" not in msg:
                continue  # notifications
            method, mid = msg["method"], msg["id"]
            # A server-side log notification first: must be ignored by the client.
            print(json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info"}}), flush=True)
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake"}}
            elif method == "tools/list":
                if (msg.get("params") or {}).get("cursor") == "p2":
                    result = {"tools": [{"name": "delete_all", "description": "Deletes", "inputSchema": {"type": "object"}}]}
                else:
                    result = {"tools": [{"name": "echo", "description": "Echoes", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}], "nextCursor": "p2"}
            elif method == "tools/call":
                args = msg["params"]["arguments"]
                if args.get("fail"):
                    result = {"content": [{"type": "text", "text": "boom"}], "isError": True}
                else:
                    result = {"content": [{"type": "text", "text": "echo: " + args.get("text", "")}, {"type": "image", "data": "x"}]}
            else:
                print(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "no such method"}}), flush=True)
                continue
            print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
        """#

    @Test func stdioServerListsAndCallsTools() async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "fake-mcp-\(UUID().uuidString).py")
        try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let client = MCPClient(transport: StdioTransport(command: "/usr/bin/python3", arguments: ["-I", "-u", script.path], timeout: .seconds(20)))
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["echo", "delete_all"], "both pages")
        #expect(tools.allSatisfy { !$0.readOnly }, "strict default")
        #expect(await client.serverName == "fake")
        let result = try await client.callTool("echo", arguments: ["text": "hi"])
        #expect(result.text == "echo: hi\n[image content]" && !result.isError)
        #expect(try await client.callTool("echo", arguments: ["fail": true]).isError)
        await client.close()
    }

    @Test func missingProgramFailsClearly() async {
        let client = MCPClient(transport: StdioTransport(command: "definitely-not-a-real-mcp-server-xyz", arguments: [], timeout: .seconds(5)))
        await #expect(throws: (any Error).self) { try await client.listTools() }
    }

    @Test func httpJSONAndSSEWithSession() async throws {
        let sessions = Mutex<[String?]>([])
        let (session, base) = StubURLProtocol.make { request, body in
            sessions.withLock { $0.append(request.value(forHTTPHeaderField: "Mcp-Session-Id")) }
            let message = try! JSONDecoder().decode(JSONValue.self, from: body)
            let id = message["id"]?.intValue ?? 0
            switch message["method"]?.stringValue {
            case "initialize":
                return .init(body: Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"serverInfo":{"name":"remote"}}}"#.utf8))
            case "tools/list":
                let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"tools\":[{\"name\":\"search\",\"inputSchema\":{\"type\":\"object\"}}]}}\n\n"
                return .init(body: Data(sse.utf8), contentType: "text/event-stream")
            default:
                return .init(status: 202, body: Data())
            }
        }
        // The stub can't set response headers per request, so the session id is checked as "sent back if received".
        let client = MCPClient(transport: HTTPTransport(endpoint: base.appending(path: "mcp"), headers: ["Authorization": "Bearer t"], session: session))
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["search"])
        #expect(sessions.withLock { $0 }.count == 3, "initialize, initialized notification, tools/list")
    }

    @Test func httpSignInRequiredIsExplained() async {
        let (session, base) = StubURLProtocol.make { _, _ in .init(status: 401, body: Data()) }
        let client = MCPClient(transport: HTTPTransport(endpoint: base, session: session))
        do {
            _ = try await client.listTools()
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("OAuth"))
        }
    }

    @Test func toolsAreStrictByDefault() async throws {
        let client = MCPClient(transport: StdioTransport(command: "/usr/bin/true", arguments: []))
        let tool = MCPTool(server: "My Server!", info: MCPToolInfo(name: "create-page", description: "Creates", inputSchema: ["type": "object"]), remote: true, client: client)
        #expect(tool.spec.name == "mcp_my_server_create_page")
        #expect(tool.dataClass == .private && tool.effect == .write && tool.sendsDataExternally)
        let local = MCPTool(server: "s", info: MCPToolInfo(name: "get", description: "", inputSchema: [:], readOnly: true), remote: false, client: client)
        #expect(local.effect == .read && !local.sendsDataExternally && local.dataClass == .private)
        #expect(MCPTool.modelName(server: String(repeating: "x", count: 80), tool: "t").count == 64)
    }

    @Test func importFromClaudeConfigLeavesSecretsOut() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "claude-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"""
            {"mcpServers":{
              "atlassian":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp"},
              "files":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/tmp"],"env":{"API_TOKEN":"secret","LOG":"1"}},
              "api":{"type":"http","url":"https://x.example/mcp","headers":{"Authorization":"Bearer secret"}}}}
            """#.write(to: file, atomically: true, encoding: .utf8)
        let found = MCPConfigImport.found(files: [file])
        #expect(found.map(\.config.name) == ["api", "atlassian", "files"])
        let files = try #require(found.first { $0.config.name == "files" })
        #expect(files.config.command == "npx" && files.config.environment == ["LOG": "1"] && files.omittedSecrets == ["API_TOKEN"])
        #expect(found.first { $0.config.name == "atlassian" }?.note?.contains("OAuth") == true)
        #expect(found.first { $0.config.name == "api" }?.config.secretHeaders == ["Authorization"])
    }
}
