import Foundation

public struct ToolOutput: Sendable {
    let contents: [MCP.Tool.Content]

    public static func text(_ text: String) -> Self {
        Self(contents: [.text(text: text, annotations: nil, _meta: nil)])
    }
}

public struct ToolContext: Sendable {}

public struct Tool: Sendable {
    let definition: MCP.Tool
    let invoke: @Sendable (CallTool.Parameters, ToolContext) async throws -> ToolOutput

    public init(
        _ name: String,
        _ description: String,
        handler: @escaping @Sendable (ToolContext) async throws -> ToolOutput
    ) {
        definition = MCP.Tool(name: name, description: description, inputSchema: .object([
            "type": .string("object"), "properties": .object([:]), "required": .array([])
        ]))
        invoke = { _, context in try await handler(context) }
    }
}

@resultBuilder
public enum ToolBuilder {
    public static func buildBlock(_ tools: Tool...) -> [Tool] { tools }
}

public struct MCPServer: Sendable {
    private let server: Server
    private let tools: [Tool]

    public init(
        name: String,
        version: String,
        instructions: String? = nil,
        @ToolBuilder tools: () -> [Tool]
    ) throws {
        self.tools = tools()
        server = Server(name: name, version: version, instructions: instructions, capabilities: .init(tools: .init()))
    }

    public func start(transport: any Transport) async throws {
        let tools = tools
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools.map(\.definition))
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = tools.first(where: { $0.definition.name == params.name }) else {
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
            let output = try await tool.invoke(params, ToolContext())
            return .init(content: output.contents, isError: false)
        }
        try await server.start(transport: transport)
    }

    public func stop() async { await server.stop() }
}
