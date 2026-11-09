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
            "type": .string("object"), "properties": .object([:]), "required": .array([]), "additionalProperties": .bool(false)
        ]))
        let result = try await client.callTool(name: "ping")
        #expect(result.isError == false)
        #expect(result.content == [.text(text: "pong", annotations: nil, _meta: nil)])
    }
}

struct CallArgs: ToolInput { let frame: Int }

@Test func annotationsSurviveDiscoveryForEveryHandlerShape() async throws {
    let hints = MCP.Tool.Annotations(
        title: "Read frame", readOnlyHint: true, destructiveHint: false,
        idempotentHint: false, openWorldHint: false
    )
    let server = try MCPServer(name: "annotations", version: "1") {
        Tool("ping", "Ping", annotations: hints) { _ in .text("pong") }
        Tool("frame", "Frame", input: CallArgs.self, annotations: hints) { args in .text("\(args.frame)") }
        Tool("progress", "Progress", input: CallArgs.self, annotations: hints) { args, _ in .text("\(args.frame)") }
        Tool("default", "Default") { _ in .text("default") }
    }
    try await withClient(server) { client, _ in
        let tools = try await client.listTools().tools
        #expect(tools.count == 4)
        for tool in tools.prefix(3) {
            #expect(tool.annotations == hints)
            let wire = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(tool))
            #expect(wire.objectValue?["annotations"] == .object([
                "title": .string("Read frame"), "readOnlyHint": .bool(true),
                "destructiveHint": .bool(false), "idempotentHint": .bool(false), "openWorldHint": .bool(false)
            ]))
        }
        #expect(tools.last?.annotations.isEmpty == true)
    }
}

struct HandlerFailure: LocalizedError {
    var errorDescription: String? { "Render failed" }
}

@Test func callFailuresAreActionableAndUnknownToolsAreProtocolErrors() async throws {
    let server = try MCPServer(name: "errors", version: "1") {
        Tool("frame", "A frame", input: CallArgs.self) { args in .text("\(args.frame)") }
        Tool("fail", "Throws") { _ in throw HandlerFailure() }
    }
    try await withClient(server) { client, _ in
        for arguments: [String: Value] in [[:], ["frame": .string("wrong")], ["frame": .null]] {
            let result = try await client.callTool(name: "frame", arguments: arguments)
            #expect(result.isError == true)
            guard case .text(let text, _, _) = result.content.first else {
                Issue.record("Expected a text error")
                continue
            }
            #expect(text.contains("frame"))
            #expect(text.count > "frame".count)
        }
        let failure = try await client.callTool(name: "fail")
        #expect(failure.isError == true)
        #expect(failure.content == [.text(text: "Render failed", annotations: nil, _meta: nil)])
        do {
            _ = try await client.callTool(name: "unknown")
            Issue.record("Expected a protocol error")
        } catch let error as MCPError {
            #expect(error.code == -32602)
        }
    }
}

struct JSONPayload: Encodable { let frame: Int; let label: String }

@Test func structuredOutputPreservesValueAndText() async throws {
    let payload = JSONPayload(frame: 3, label: "hello")
    let server = try MCPServer(name: "structured", version: "1") {
        Tool("automatic", "JSON fallback") { _ in try .structured(payload) }
        Tool("caption", "Custom text") { _ in try .structured(payload, text: "Rendered") }
        Tool("empty", "Empty text") { _ in try .structured(payload, text: "") }
    }
    try await withClient(server) { client, _ in
        let expected: Value = .object(["frame": .int(3), "label": .string("hello")])
        for name in ["automatic", "caption", "empty"] {
            let request = try await client.send(CallTool.request(.init(name: name)))
            let result = try await request.value
            #expect(result.structuredContent == expected)
            #expect(result.isError == false)
            #expect(result.content.count == 1)
            let content = try #require(result.content.first)
            guard case .text(let text, _, _) = content else {
                Issue.record("Expected text fallback")
                continue
            }
            if name == "automatic" {
                #expect(try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == expected)
            } else {
                #expect(text == (name == "caption" ? "Rendered" : ""))
            }
        }
    }
}

@Test func outputFormatsPreserveTheirContent() async throws {
    let bytes = Data([0, 1, 2, 255])
    let raw: [MCP.Tool.Content] = [
        .audio(data: "YWJj", mimeType: "audio/wav", annotations: nil, _meta: .init(additionalFields: ["source": .string("raw")])),
        .text(text: "caption", annotations: nil, _meta: nil)
    ]
    let server = try MCPServer(name: "outputs", version: "1") {
        Tool("json", "JSON") { _ in try .json(JSONPayload(frame: 3, label: "hello")) }
        Tool("image", "Image") { _ in .image(bytes, mimeType: "image/png") }
        Tool("raw", "Raw") { _ in .content(raw) }
    }
    try await withClient(server) { client, _ in
        let json = try await client.callTool(name: "json")
        guard case .text(let text, _, _) = json.content.first else {
            Issue.record("Expected JSON text")
            return
        }
        #expect(try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == .object(["frame": .int(3), "label": .string("hello")]))
        #expect(json.isError == false)
        let image = try await client.callTool(name: "image")
        #expect(image.content == [.image(data: bytes.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil)])
        let content = try await client.callTool(name: "raw")
        #expect(content.content == raw)
    }
}

@Test func duplicateToolNamesAreRejected() throws {
    do {
        _ = try MCPServer(name: "duplicates", version: "1") {
            Tool("ping", "First") { _ in .text("first") }
            Tool("ping", "Second") { _ in .text("second") }
        }
        Issue.record("Accepted duplicate tool names")
    } catch MCPKitServerError.duplicateTool(let name) {
        #expect(name == "ping")
    }
}

private enum LookupError: Error { case projectNotFound(String) }
private enum UndescribedError: LocalizedError { case missingDescription }

@Test func plainSwiftErrorReachesTheModel() async throws {
    let server = try MCPServer(name: "errors", version: "1") {
        Tool("fail", "Fails") { _ in throw LookupError.projectNotFound("demo") }
        Tool("undescribed", "No localized description") { _ in throw UndescribedError.missingDescription }
    }
    try await withClient(server) { client, _ in
        for (name, expected) in [
            ("fail", String(describing: LookupError.projectNotFound("demo"))),
            ("undescribed", String(describing: UndescribedError.missingDescription))
        ] {
            let result = try await client.callTool(name: name)
            #expect(result.isError == true)
            #expect(result.content == [.text(text: expected, annotations: nil, _meta: nil)])
        }
    }
}
