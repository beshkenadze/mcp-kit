import Foundation
import Testing
import MCPKitServer

func withClient(
    _ server: MCPServer,
    _ body: (Client, Initialize.Result) async throws -> Void
) async throws {
    let transports = await InMemoryTransport.createConnectedPair()
    let client = Client(name: "tests", version: "1")
    try await server.start(transport: transports.server)
    do {
        let initialized = try await client.connect(transport: transports.client)
        try await body(client, initialized)
    } catch {
        await client.disconnect()
        await server.stop()
        throw error
    }
    await client.disconnect()
    await server.stop()
}

@Test func discoversAndCallsNoInputTool() async throws {
    let server = try MCPServer(name: "example", version: "1", instructions: "Use ping.") {
        Tool("ping", "Health check") { _ in .text("pong") }
    }
    try await withClient(server) { client, initialized in
        #expect(initialized.serverInfo.name == "example")
        #expect(initialized.serverInfo.version == "1")
        #expect(initialized.instructions == "Use ping.")
        #expect(initialized.capabilities.tools != nil)
        #expect(initialized.capabilities.resources == nil)
        #expect(initialized.capabilities.prompts == nil)
        let tools = try await client.listTools()
        #expect(tools.nextCursor == nil)
        #expect(tools.tools.count == 1)
        let tool = try #require(tools.tools.first)
        #expect(tool.name == "ping")
        #expect(tool.description == "Health check")
        #expect(tool.inputSchema == .object([
            "type": .string("object"), "properties": .object([:]), "required": .array([])
        ]))
        let result = try await client.callTool(name: "ping")
        #expect(result.isError == false)
        #expect(result.content == [.text(text: "pong", annotations: nil, _meta: nil)])
    }
}
