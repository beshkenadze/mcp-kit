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

private enum ReusableMode: String, ToolInputEnum { case read, write }

private struct ReusableChild: ToolInput {
    let label: String
    static let constraints: [String: [SchemaConstraint]] = ["label": [.length(1...3)]]
}

private struct ReusableInput: ToolInput {
    let count: Int
    let note: String?
    let children: [ReusableChild]
    let mode: ReusableMode
    let flags: [String: Bool]?
    static let descriptions = ["count": "Item count"]
    static let constraints: [String: [SchemaConstraint]] = [
        "count": [.range(1...3)], "note": [.length(0...4)], "children": [.items(1...2)]
    ]
}

@Test func toolInputPublishesAndValidatesTheSameSchemaAsTheServer() async throws {
    let schema = try ReusableInput.inputSchema()
    let server = try MCPServer(name: "reusable", version: "1") {
        Tool("check", "Check", input: ReusableInput.self) { _ in .text("accepted") }
    }
    try await withClient(server) { client, _ in
        let published = try #require(try await client.listTools().tools.first?.inputSchema)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(published) == encoder.encode(schema))
        let valid: [String: Value] = ["count": 2, "children": [["label": "ok"]], "mode": "read"]
        try ReusableInput.validate(valid)
        var cases: [[String: Value]] = []
        var missing = valid
        missing.removeValue(forKey: "count")
        cases.append(missing)
        for (key, value): (String, Value) in [
            ("unknown", true), ("count", "2"), ("count", 0), ("count", 4), ("count", .null),
            ("note", "longer"), ("note", .null), ("children", []), ("children", [["label": "long"]]),
            ("children", [["label": .null]]), ("children", [["label": "ok", "extra": true]]),
            ("mode", "other"), ("flags", ["bad": .null]), ("flags", ["bad": 1])
        ] {
            var input = valid
            input[key] = value
            cases.append(input)
        }
        for arguments in cases {
            let message: String
            do { try ReusableInput.validate(arguments); Issue.record("Accepted invalid arguments"); continue }
            catch { message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error) }
            let result = try await client.callTool(name: "check", arguments: arguments)
            #expect(result.isError == true)
            #expect(result.content == [.text(text: message, annotations: nil, _meta: nil)])
        }
        let result = try await client.callTool(name: "check", arguments: valid)
        #expect(result.isError == false)
    }
}

private struct NarrowIntegerInput: ToolInput { let value: Int8 }

@Test func publicValidationMatchesServerDecodingErrors() async throws {
    let server = try MCPServer(name: "narrow", version: "1") {
        Tool("narrow", "Narrow integer", input: NarrowIntegerInput.self) { _ in .text("accepted") }
    }
    try await withClient(server) { client, _ in
        for value in [-129, 128] {
            let arguments: [String: Value] = ["value": .int(value)]
            let message: String
            do { try NarrowIntegerInput.validate(arguments); Issue.record("Accepted out-of-range Int8"); continue }
            catch { message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error) }
            let result = try await client.callTool(name: "narrow", arguments: arguments)
            #expect(result.isError == true)
            #expect(result.content == [.text(text: message, annotations: nil, _meta: nil)])
        }
        try NarrowIntegerInput.validate(["value": 127])
        let result = try await client.callTool(name: "narrow", arguments: ["value": 127])
        #expect(result.isError == false)
    }
}
