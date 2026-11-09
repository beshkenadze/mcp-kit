import Testing
import MCPKitServer

private struct BoundedSchedule: ToolInput {
    let start_minute: Int
    let end_minute: Int
    static let constraints: [String: [SchemaConstraint]] = [
        "start_minute": [.range(0...1439)], "end_minute": [.range(0...1439)]
    ]
}

private struct BoundedConfigure: ToolInput {
    let intensity: Double?
    let target_minutes: Int?
    let schedule: BoundedSchedule?
    static let constraints: [String: [SchemaConstraint]] = [
        "intensity": [.range(0...1)], "target_minutes": [.range(1...1440)]
    ]
}

@Test func numericConstraintsArePublishedAndEnforcedAtTheirBoundaries() async throws {
    let server = try MCPServer(name: "constraints", version: "1") {
        Tool("configure", "Configure", input: BoundedConfigure.self) { _ in .text("accepted") }
    }
    try await withClient(server) { client, _ in
        let tool = try #require(try await client.listTools().tools.first)
        let fields = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(fields["intensity"] == .object(["type": "number", "minimum": 0, "maximum": 1]))
        #expect(fields["target_minutes"] == .object(["type": "integer", "minimum": 1, "maximum": 1440]))
        let schedule = try #require(fields["schedule"]?.objectValue?["properties"]?.objectValue)
        for key in ["start_minute", "end_minute"] {
            #expect(schedule[key] == .object(["type": "integer", "minimum": 0, "maximum": 1439]))
        }
        let cases: [([String: Value], Bool)] = [
            ([:], true), (["intensity": 0], true), (["intensity": 0.5], true), (["intensity": 1], true),
            (["intensity": -0.01], false), (["intensity": 1.1], false),
            (["target_minutes": 1], true), (["target_minutes": 720], true), (["target_minutes": 1440], true),
            (["target_minutes": 0], false), (["target_minutes": 1441], false),
            (["schedule": ["start_minute": 0, "end_minute": 1439]], true),
            (["schedule": ["start_minute": 720, "end_minute": 720]], true),
            (["schedule": ["start_minute": 1439, "end_minute": 0]], true),
            (["schedule": ["start_minute": -1, "end_minute": 20]], false),
            (["schedule": ["start_minute": 1440, "end_minute": 20]], false),
            (["schedule": ["start_minute": 20, "end_minute": -1]], false),
            (["schedule": ["start_minute": 20, "end_minute": 1440]], false)
        ]
        for (arguments, accepted) in cases {
            let result = try await client.callTool(name: "configure", arguments: arguments)
            #expect(result.isError == !accepted, "\(arguments)")
        }
    }
}
