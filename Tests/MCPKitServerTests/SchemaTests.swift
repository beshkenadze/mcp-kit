import Foundation
import Testing
import MCPKitServer

struct Scalars: ToolInput {
    let text: String
    let url: URL
    let int: Int
    let int8: Int8
    let int16: Int16
    let int32: Int32
    let int64: Int64
    let uint: UInt
    let uint8: UInt8
    let uint16: UInt16
    let uint32: UInt32
    let uint64: UInt64
    let double: Double
    let float: Float
    let bool: Bool
    let optional: String?
    static let descriptions = ["text": "Some text", "optional": "May be omitted"]
}

@Test func scalarSchemasAndOptionalFields() async throws {
    let server = try MCPServer(name: "schemas", version: "1") {
        Tool("scalars", "Scalar arguments", input: Scalars.self) { args in .text(args.text) }
    }
    try await withClient(server) { client, _ in
        let tool = try #require(try await client.listTools().tools.first)
        let schema = try #require(tool.inputSchema.objectValue)
        let fields = try #require(schema["properties"]?.objectValue)
        #expect(fields["text"] == .object(["type": .string("string"), "description": .string("Some text")]))
        #expect(fields["url"] == .object(["type": .string("string"), "format": .string("uri")]))
        for key in ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64"] {
            #expect(fields[key] == .object(["type": .string("integer")]))
        }
        for key in ["float", "double"] { #expect(fields[key] == .object(["type": .string("number")])) }
        #expect(fields["bool"] == .object(["type": .string("boolean")]))
        #expect(fields["optional"] == .object(["type": .string("string"), "description": .string("May be omitted")]))
        #expect(Set(schema["required"]?.arrayValue ?? []) == Set(fields.keys.filter { $0 != "optional" }.map(Value.string)))
        let result = try await client.callTool(name: "scalars", arguments: [
            "text": .string("hello"), "url": .string("https://example.com"),
            "int": .int(1), "int8": .int(8), "int16": .int(16), "int32": .int(32), "int64": .int(64),
            "uint": .int(1), "uint8": .int(8), "uint16": .int(16), "uint32": .int(32), "uint64": .int(64),
            "double": .double(1.5), "float": .double(2.5), "bool": .bool(true)
        ])
        #expect(result.content == [.text(text: "hello", annotations: nil, _meta: nil)])
    }
}

struct Details: ToolInput {
    let title: String
    let enabled: Bool?
    static let descriptions = ["title": "Nested title"]
}

struct Collections: ToolInput {
    let details: Details
    let numbers: [Int]
    let objects: [Details]
    let labels: [String: String]
    let records: [String: Details]
}

@Test func nestedObjectsArraysAndDictionaries() async throws {
    let server = try MCPServer(name: "schemas", version: "1") {
        Tool("collections", "Nested arguments", input: Collections.self) { args in
            .text("\(args.objects.first?.title ?? ""):\(args.numbers.reduce(0, +)):\(args.labels["a"] ?? "")")
        }
    }
    try await withClient(server) { client, _ in
        let tool = try #require(try await client.listTools().tools.first)
        let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        let details: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"), "description": .string("Nested title")]),
                "enabled": .object(["type": .string("boolean")])
            ]), "required": .array([.string("title")])
        ])
        #expect(properties["details"] == details)
        #expect(properties["objects"] == .object(["type": .string("array"), "items": details]))
        #expect(properties["numbers"] == .object(["type": .string("array"), "items": .object(["type": .string("integer")])]))
        #expect(properties["labels"] == .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string")])]))
        #expect(properties["records"] == .object(["type": .string("object"), "additionalProperties": details]))
        let result = try await client.callTool(name: "collections", arguments: [
            "details": .object(["title": .string("root")]), "numbers": .array([.int(2), .int(3)]),
            "objects": .array([.object(["title": .string("child")])]),
            "labels": .object(["a": .string("label")]), "records": .object([:])
        ])
        #expect(result.content == [.text(text: "child:5:label", annotations: nil, _meta: nil)])
    }
}

enum Format: String, ToolInputEnum { case png, jpeg }
struct EnumArgs: ToolInput {
    let format: Format
    let formats: [Format]
    let optional: Format?
}
struct EmptyArgs: ToolInput {}

@Test func enumAndEmptyObjectInputs() async throws {
    let server = try MCPServer(name: "schemas", version: "1") {
        Tool("enum", "Formats", input: EnumArgs.self) { args in .text(args.format.rawValue) }
        Tool("empty", "Empty", input: EmptyArgs.self) { _ in .text("empty") }
    }
    try await withClient(server) { client, _ in
        let tools = try await client.listTools().tools
        let schema = try #require(tools.first?.inputSchema.objectValue)
        let fields = try #require(schema["properties"]?.objectValue)
        let enumeration: Value = .object(["type": .string("string"), "enum": .array([.string("png"), .string("jpeg")])])
        #expect(fields["format"] == enumeration)
        #expect(fields["formats"] == .object(["type": .string("array"), "items": enumeration]))
        #expect(fields["optional"] == enumeration)
        #expect(schema["required"] == .array([.string("format"), .string("formats")]))
        #expect(tools.last?.inputSchema == .object(["type": .string("object"), "properties": .object([:]), "required": .array([])]))
        let result = try await client.callTool(name: "enum", arguments: ["format": .string("jpeg"), "formats": .array([])])
        #expect(result.content == [.text(text: "jpeg", annotations: nil, _meta: nil)])
        let empty = try await client.callTool(name: "empty")
        #expect(empty.content == [.text(text: "empty", annotations: nil, _meta: nil)])
    }
}

struct DateArgs: ToolInput { let date: Date }
struct DataArgs: ToolInput { let data: Data }
struct DecimalArgs: ToolInput { let decimal: Decimal }
struct SetArgs: ToolInput { let set: Set<String> }
struct ScalarRoot: ToolInput {
    init(from decoder: any Decoder) throws { _ = try decoder.singleValueContainer().decode(String.self) }
}
final class RecursiveArgs: ToolInput { let children: [RecursiveArgs] }
enum EnumRoot: String, ToolInput, ToolInputEnum { case value }
struct ArrayRoot: ToolInput {
    init(from decoder: any Decoder) throws { _ = try [String](from: decoder) }
}

@Test func unsupportedInputsFailDuringConstruction() throws {
    func rejects<T: ToolInput>(_ type: T.Type) {
        do {
            _ = try MCPServer(name: "bad", version: "1") {
                Tool("unsupported", "Must fail", input: type) { _ in .text("never") }
            }
            Issue.record("Accepted unsupported input \(type)")
        } catch MCPKitServerError.unsupportedInput(let tool, let reason) {
            #expect(tool == "unsupported")
            #expect(!reason.isEmpty)
        } catch { Issue.record("Unexpected error: \(error)") }
    }
    rejects(DateArgs.self)
    rejects(DataArgs.self)
    rejects(DecimalArgs.self)
    rejects(SetArgs.self)
    rejects(ScalarRoot.self)
    rejects(ArrayRoot.self)
    rejects(EnumRoot.self)
    rejects(RecursiveArgs.self)
}

struct BoundedRecursive: ToolInput {
    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count < 8 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Probe depth limit"))
        }
        let container = try decoder.container(keyedBy: Keys.self)
        _ = try container.decode([BoundedRecursive].self, forKey: .children)
    }
    enum Keys: String, CodingKey { case children }
}

@Test func recursiveInputIsRejectedWithADiagnostic() {
    do {
        _ = try MCPServer(name: "bad", version: "1") {
            Tool("recursive", "Recursive", input: BoundedRecursive.self) { _ in .text("never") }
        }
        Issue.record("Accepted recursive input")
    } catch MCPKitServerError.unsupportedInput(let tool, let reason) {
        #expect(tool == "recursive")
        #expect(reason.contains("Recursive input"))
    } catch { Issue.record("Unexpected error: \(error)") }
}

struct SwallowedUnsupported: ToolInput {
    let date: Date?
    enum Keys: String, CodingKey { case date }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        date = try? container.decode(Date.self, forKey: .date)
    }
}

@Test func unsupportedFieldsCannotBeHiddenByCustomDecoders() {
    do {
        _ = try MCPServer(name: "bad", version: "1") {
            Tool("swallowed", "Unsupported", input: SwallowedUnsupported.self) { _ in .text("never") }
        }
        Issue.record("Accepted a swallowed unsupported field")
    } catch MCPKitServerError.unsupportedInput(let tool, let reason) {
        #expect(tool == "swallowed")
        #expect(reason.contains("date"))
    } catch { Issue.record("Unexpected error: \(error)") }
}

private struct Typo: ToolInput {
    let frame: Int
    static let descriptions = ["fram": "Frame number"]
}

private struct RenamedDescriptionTypo: ToolInput {
    let frame: Int
    enum CodingKeys: String, CodingKey { case frame = "frame_number" }
    static let descriptions = ["frame": "Frame number"]
}

@Test func descriptionForUnknownFieldIsRejected() {
    func rejects<Input: ToolInput>(_ type: Input.Type, unknownKey: String) {
        do {
            _ = try MCPServer(name: "descriptions", version: "1") {
                Tool("t", "A frame", input: type) { _ in .text("") }
            }
            Issue.record("Accepted description for unknown field \(unknownKey)")
        } catch MCPKitServerError.unsupportedInput(let tool, let reason) {
            #expect(tool == "t")
            #expect(reason.contains(unknownKey))
        } catch { Issue.record("Unexpected error: \(error)") }
    }
    rejects(Typo.self, unknownKey: "fram")
    rejects(RenamedDescriptionTypo.self, unknownKey: "frame")
}
