import Testing
import MCPKitServer

private enum Category: String, ToolInputEnum { case genre, tempo }
private struct Tag: ToolInput { let category: Category; let value: String }
private struct Schedule: ToolInput { let start_minute: Int; let end_minute: Int }
private struct Configure: ToolInput {
    let intensity: Double?
    let target_minutes: Int?
    let schedule: Schedule?
    let tags: [Tag]?
    let labels: [String: String]?
    let records: [String: Tag]?
    let enabled: Bool?
}

@Test func rawArgumentsAreValidatedRecursivelyBeforeDecoding() async throws {
    let server = try MCPServer(name: "strict", version: "1") {
        Tool("configure", "Configure", input: Configure.self) { _ in .text("accepted") }
        Tool("ping", "Ping") { _ in .text("accepted") }
        Tool("empty", "Empty", input: EmptyArgs.self) { _ in .text("accepted") }
    }
    try await withClient(server) { client, _ in
        let invalid: [([String: Value], String)] = [
            (["unknown": 1], "$.unknown"),
            (["schedule": ["start_minute": 10, "end_minute": 20, "unknown": 1]], "$.schedule.unknown"),
            (["tags": [["category": "genre", "value": "warm", "unknown": 1]]], "$.tags[0].unknown"),
            (["target_minutes": .null], "$.target_minutes"),
            (["schedule": .null], "$.schedule"),
            (["schedule": ["start_minute": .null, "end_minute": 20]], "$.schedule.start_minute"),
            (["tags": [.null]], "$.tags[0]"),
            (["labels": ["custom": .null]], "$.labels.custom"),
            (["records": ["custom": ["category": "genre", "value": "warm", "extra": 1]]], "$.records.custom.extra"),
            (["schedule": ["start_minute": 10]], "$.schedule.end_minute"),
            (["target_minutes": "10"], "$.target_minutes"),
            (["target_minutes": true], "$.target_minutes"),
            (["target_minutes": 1.5], "$.target_minutes"),
            (["intensity": false], "$.intensity"),
            (["schedule": []], "$.schedule"),
            (["tags": [:]], "$.tags"),
            (["labels": ["custom": 1]], "$.labels.custom"),
            (["tags": [["category": "unknown", "value": "warm"]]], "$.tags[0].category"),
            (["tags": [["category": "genre", "value": false]]], "$.tags[0].value"),
            (["enabled": 1], "$.enabled")
        ]
        for (arguments, path) in invalid {
            let result = try await client.callTool(name: "configure", arguments: arguments)
            #expect(result.isError == true, "Accepted \(arguments)")
            let content = try #require(result.content.first)
            guard case .text(let text, _, _) = content else {
                Issue.record("Expected a field diagnostic")
                continue
            }
            #expect(text.contains(path), "Expected \(path) in \(text)")
        }
        for name in ["ping", "empty"] {
            let result = try await client.callTool(name: name, arguments: ["unknown": 1])
            #expect(result.isError == true)
        }
        for arguments: [String: Value] in [
            [:], ["intensity": 1, "enabled": true],
            ["labels": ["arbitrary": "value"], "records": ["arbitrary": ["category": "tempo", "value": "slow"]]],
            ["schedule": ["start_minute": 0, "end_minute": 1439], "tags": []]
        ] {
            let result = try await client.callTool(name: "configure", arguments: arguments)
            #expect(result.isError == false)
            #expect(result.content == [.text(text: "accepted", annotations: nil, _meta: nil)])
        }
        let tools = try await client.listTools().tools
        for tool in tools { #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false)) }
    }
}
