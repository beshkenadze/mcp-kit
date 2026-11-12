import Foundation
import Testing
import MCPKitServer

@Test func structuredOutputMustBeAnObject() async throws {
    for value: Value in [.array([1, 2, 3]), .string("text"), .int(1), .double(1.5), .bool(true), .null] {
        #expect(throws: (any Error).self) { try ToolOutput.structured(value) }
    }
    let server = try MCPServer(name: "structured", version: "1") {
        Tool("invalid", "Invalid structured output") { _ in try .structured([1, 2, 3]) }
    }
    try await withClient(server) { client, _ in
        let result = try await client.send(CallTool.request(.init(name: "invalid"))).value
        #expect(result.structuredContent == nil)
        #expect(result.isError == true)
        #expect(result.content == [.text(text: "Structured output must be a JSON object", annotations: nil, _meta: nil)])
    }
}
