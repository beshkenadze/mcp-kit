import Foundation

public struct ToolOutput: Sendable {
    let contents: [MCP.Tool.Content]
    let structuredContent: Value?

    private init(contents: [MCP.Tool.Content], structuredContent: Value? = nil) {
        self.contents = contents
        self.structuredContent = structuredContent
    }

    public static func text(_ text: String) -> Self {
        Self(contents: [.text(text: text, annotations: nil, _meta: nil)])
    }

    public static func json(_ value: some Encodable) throws -> Self {
        let data = try JSONEncoder().encode(value)
        return .text(String(decoding: data, as: UTF8.self))
    }

    public static func structured(_ value: some Encodable, text: String? = nil) throws -> Self {
        let data = try JSONEncoder().encode(value)
        let structured = try JSONDecoder().decode(Value.self, from: data)
        return Self(
            contents: [.text(text: text ?? String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: structured
        )
    }

    public static func image(_ data: Data, mimeType: String) -> Self {
        Self(contents: [.image(data: data.base64EncodedString(), mimeType: mimeType, annotations: nil, _meta: nil)])
    }

    public static func content(_ content: [MCP.Tool.Content]) -> Self {
        Self(contents: content)
    }
}

public struct ToolContext: Sendable {
    let server: Server?
    let progressToken: ProgressToken?

    public func progress(_ progress: Double, total: Double? = nil, message: String? = nil) async {
        guard let server, let progressToken else { return }
        do {
            try await server.notify(ProgressNotification.message(.init(
                progressToken: progressToken, progress: progress, total: total, message: message
            )))
        } catch {
            FileHandle.standardError.write(Data("MCPKitServer progress: \(error.localizedDescription)\n".utf8))
        }
    }
}

public struct Tool: Sendable {
    let name: String
    let description: String
    let annotations: MCP.Tool.Annotations
    let schema: @Sendable () throws -> Value
    let invoke: @Sendable (CallTool.Parameters, ToolContext) async throws -> ToolOutput

    public init(
        _ name: String,
        _ description: String,
        annotations: MCP.Tool.Annotations = nil,
        handler: @escaping @Sendable (ToolContext) async throws -> ToolOutput
    ) {
        self.name = name
        self.description = description
        self.annotations = annotations
        schema = { .object([
            "type": .string("object"), "properties": .object([:]), "required": .array([])
        ]) }
        invoke = { _, context in try await handler(context) }
    }

    public init<Input: ToolInput>(
        _ name: String,
        _ description: String,
        input: Input.Type,
        annotations: MCP.Tool.Annotations = nil,
        handler: @escaping @Sendable (Input) async throws -> ToolOutput
    ) {
        self.init(name, description, input: input, annotations: annotations) { arguments, _ in try await handler(arguments) }
    }

    public init<Input: ToolInput>(
        _ name: String,
        _ description: String,
        input: Input.Type,
        annotations: MCP.Tool.Annotations = nil,
        handler: @escaping @Sendable (Input, ToolContext) async throws -> ToolOutput
    ) {
        self.name = name
        self.description = description
        self.annotations = annotations
        schema = { try SchemaDecoder.input(input) }
        invoke = { params, context in
            let data = try JSONEncoder().encode(Value.object(params.arguments ?? [:]))
            let arguments: Input
            do { arguments = try JSONDecoder().decode(Input.self, from: data) }
            catch let error as DecodingError { throw ArgumentFailure(error) }
            return try await handler(arguments, context)
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
        var names: Set<String> = []
        for tool in declarations {
            guard names.insert(tool.name).inserted else { throw MCPKitServerError.duplicateTool(tool.name) }
        }
        self.tools = declarations
        definitions = try declarations.map { tool in
            do {
                return MCP.Tool(
                    name: tool.name, description: tool.description,
                    inputSchema: try tool.schema(), annotations: tool.annotations
                )
            }
            catch { throw MCPKitServerError.unsupportedInput(tool: tool.name, reason: error.localizedDescription) }
        }
        server = Server(name: name, version: version, instructions: instructions, capabilities: .init(tools: .init()))
    }

    public func start(transport: any Transport) async throws {
        let tools = tools
        let definitions = definitions
        let server = server
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: definitions)
        }
        await server.withMethodHandler(CallTool.self) { [weak server] params in
            guard let tool = tools.first(where: { $0.name == params.name }) else {
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
            do {
                let context = ToolContext(server: server, progressToken: params._meta?.progressToken)
                let output = try await tool.invoke(params, context)
                return .init(content: output.contents, structuredContent: output.structuredContent, isError: false)
            } catch {
                let description = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
                return .init(content: ToolOutput.text(description).contents, isError: true)
            }
        }
        try await server.start(transport: transport)
    }

    public func stop() async { await server.stop() }

    public func runStdio() async throws {
        try await start(transport: StdioTransport())
        await withTaskCancellationHandler {
            await server.waitUntilCompleted()
        } onCancel: {
            Task { await server.stop() }
        }
        await server.stop()
    }
}

private struct ArgumentFailure: LocalizedError {
    let errorDescription: String?

    init(_ error: DecodingError) {
        let path: [any CodingKey]
        let reason: String
        switch error {
        case .keyNotFound(let key, let context):
            path = context.codingPath + [key]
            reason = "Required field is missing"
        case .typeMismatch(let type, let context):
            path = context.codingPath
            reason = "Expected \(type). \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            path = context.codingPath
            reason = "Expected \(type), received null"
        case .dataCorrupted(let context):
            path = context.codingPath
            reason = context.debugDescription
        @unknown default:
            path = []
            reason = error.localizedDescription
        }
        let field = path.map(\.stringValue).joined(separator: ".")
        errorDescription = "Invalid arguments at \(field.isEmpty ? "<root>" : field): \(reason)"
    }
}
