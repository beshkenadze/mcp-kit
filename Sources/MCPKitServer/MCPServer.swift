import Foundation

public struct ToolOutput: Sendable {
    let contents: [MCP.Tool.Content]

    public static func text(_ text: String) -> Self {
        Self(contents: [.text(text: text, annotations: nil, _meta: nil)])
    }
}

public struct ToolContext: Sendable {}

public struct Tool: Sendable {
    let name: String
    let description: String
    let schema: @Sendable () throws -> Value
    let invoke: @Sendable (CallTool.Parameters, ToolContext) async throws -> ToolOutput

    public init(
        _ name: String,
        _ description: String,
        handler: @escaping @Sendable (ToolContext) async throws -> ToolOutput
    ) {
        self.name = name
        self.description = description
        schema = { .object([
            "type": .string("object"), "properties": .object([:]), "required": .array([])
        ]) }
        invoke = { _, context in try await handler(context) }
    }

    public init<Input: ToolInput>(
        _ name: String,
        _ description: String,
        input: Input.Type,
        handler: @escaping @Sendable (Input) async throws -> ToolOutput
    ) {
        self.name = name
        self.description = description
        schema = { try SchemaDecoder.input(input) }
        invoke = { params, _ in
            let data = try JSONEncoder().encode(Value.object(params.arguments ?? [:]))
            return try await handler(JSONDecoder().decode(Input.self, from: data))
        }
    }
}

@resultBuilder
public enum ToolBuilder {
    public static func buildBlock(_ tools: Tool...) -> [Tool] { tools }
}

public struct MCPServer: Sendable {
    private let server: Server
    private let tools: [Tool]
    private let definitions: [MCP.Tool]

    public init(
        name: String,
        version: String,
        instructions: String? = nil,
        @ToolBuilder tools: () -> [Tool]
    ) throws {
        let declarations = tools()
        self.tools = declarations
        definitions = try declarations.map { tool in
            do { return MCP.Tool(name: tool.name, description: tool.description, inputSchema: try tool.schema()) }
            catch { throw MCPKitServerError.unsupportedInput(tool: tool.name, reason: error.localizedDescription) }
        }
        server = Server(name: name, version: version, instructions: instructions, capabilities: .init(tools: .init()))
    }

    public func start(transport: any Transport) async throws {
        let tools = tools
        let definitions = definitions
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: definitions)
        }
        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = tools.first(where: { $0.name == params.name }) else {
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
            let output = try await tool.invoke(params, ToolContext())
            return .init(content: output.contents, isError: false)
        }
        try await server.start(transport: transport)
    }

    public func stop() async { await server.stop() }
}
