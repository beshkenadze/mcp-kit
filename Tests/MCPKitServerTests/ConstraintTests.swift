import Testing
import MCPKitServer

private struct BoundedTag: ToolInput {
    let value: String
    static let constraints: [String: [SchemaConstraint]] = ["value": [.length(1...100)]]
}

private struct BoundedEnd: ToolInput {
    let bpm: Int?
    let text: String?
    let tags: [BoundedTag]?
    static let constraints: [String: [SchemaConstraint]] = [
        "bpm": [.range(30...300)], "text": [.length(0...800)], "tags": [.items(0...24)]
    ]
}

private struct BoundedMood: ToolInput {
    let name: String
    let calm: BoundedEnd
    let energetic: BoundedEnd
    let samples: [Int]?
    enum CodingKeys: String, CodingKey { case name = "mood_name", calm, energetic, samples }
    static let descriptions = ["mood_name": "Mood name"]
    static let constraints: [String: [SchemaConstraint]] = [
        "mood_name": [.length(1...80)], "samples": [.items(1...3)]
    ]
}

@Test func stringAndArrayConstraintsArePublishedAndEnforcedAtTheirBoundaries() async throws {
    let server = try MCPServer(name: "constraints", version: "1") {
        Tool("create", "Create mood", input: BoundedMood.self) { _ in .text("accepted") }
    }
    try await withClient(server) { client, _ in
        let tool = try #require(try await client.listTools().tools.first)
        let fields = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(fields["mood_name"] == .object([
            "type": "string", "description": "Mood name", "minLength": 1, "maxLength": 80
        ]))
        #expect(fields["samples"] == .object([
            "type": "array", "items": ["type": "integer"], "minItems": 1, "maxItems": 3
        ]))
        for key in ["calm", "energetic"] {
            let end = try #require(fields[key]?.objectValue?["properties"]?.objectValue)
            #expect(end["bpm"] == .object(["type": "integer", "minimum": 30, "maximum": 300]))
            #expect(end["text"] == .object(["type": "string", "minLength": 0, "maxLength": 800]))
            let tags = try #require(end["tags"]?.objectValue)
            #expect(tags["minItems"] == 0)
            #expect(tags["maxItems"] == 24)
            #expect(tags["items"]?.objectValue?["properties"]?.objectValue?["value"] == .object([
                "type": "string", "minLength": 1, "maxLength": 100
            ]))
        }
        func arguments(name: String = "Mood", end: Value = [:]) -> [String: Value] {
            ["mood_name": .string(name), "calm": end, "energetic": end]
        }
        var cases: [([String: Value], Bool)] = []
        for (count, accepted) in [(0, false), (1, true), (40, true), (80, true), (81, false)] {
            cases.append((arguments(name: String(repeating: "a", count: count)), accepted))
        }
        for (count, accepted) in [(0, true), (1, true), (400, true), (800, true), (801, false)] {
            cases.append((arguments(end: ["text": .string(String(repeating: "a", count: count))]), accepted))
        }
        for (count, accepted) in [(0, false), (1, true), (50, true), (100, true), (101, false)] {
            cases.append((arguments(end: ["tags": [["value": .string(String(repeating: "a", count: count))]]]), accepted))
        }
        for (count, accepted) in [(0, true), (1, true), (12, true), (24, true), (25, false)] {
            cases.append((arguments(end: ["tags": .array(Array(repeating: ["value": "tag"], count: count))]), accepted))
        }
        for (count, accepted) in [(0, false), (1, true), (2, true), (3, true), (4, false)] {
            var input = arguments()
            input["samples"] = .array(Array(repeating: 1, count: count))
            cases.append((input, accepted))
        }
        for (bpm, accepted) in [(29, false), (30, true), (120, true), (300, true), (301, false)] {
            cases.append((arguments(end: ["bpm": .int(bpm)]), accepted))
        }
        cases.append((arguments(name: String(repeating: "😀", count: 80)), true))
        cases.append((arguments(name: String(repeating: "e\u{301}", count: 41)), false))
        for (arguments, accepted) in cases {
            let result = try await client.callTool(name: "create", arguments: arguments)
            #expect(result.isError == !accepted, "\(arguments)")
            if !accepted {
                let content = try #require(result.content.first)
                guard case .text(let text, _, _) = content else { Issue.record("Expected diagnostic"); continue }
                #expect(text.contains("$.mood_name") || text.contains("$.calm") || text.contains("$.samples"))
            }
        }
    }
}

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
