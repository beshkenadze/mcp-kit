import Testing
import MCPKitServer

actor ProgressRecorder {
    var events: [ProgressNotification.Parameters] = []
    func append(_ event: ProgressNotification.Parameters) { events.append(event) }
}

@Test func progressUsesOnlyTheCurrentCallsToken() async throws {
    let recorder = ProgressRecorder()
    let server = try MCPServer(name: "progress", version: "1") {
        Tool("render", "Render", input: CallArgs.self) { args, context in
            await context.progress(0.5, total: 1, message: "Rendering \(args.frame)")
            return .text("done")
        }
        Tool("ping", "Ping") { context in
            await context.progress(1)
            return .text("pong")
        }
    }
    try await withClient(server) { client, _ in
        await client.onNotification(ProgressNotification.self) { message in
            await recorder.append(message.params)
        }
        _ = try await client.callTool(name: "render", arguments: ["frame": .int(1)])
        #expect(await recorder.events.isEmpty)
        for token: ProgressToken in [.string("job"), .integer(42)] {
            _ = try await client.callTool(name: "render", arguments: ["frame": .int(7)], meta: .init(progressToken: token))
            let event = try #require(await recorder.events.last)
            #expect(event.progressToken == token)
            #expect(event.progress == 0.5)
            #expect(event.total == 1)
            #expect(event.message == "Rendering 7")
        }
        _ = try await client.callTool(name: "ping", meta: .init(progressToken: .string("ping")))
        let ping = try #require(await recorder.events.last)
        #expect(ping.progressToken == .string("ping"))
        #expect(ping.progress == 1)
        #expect(ping.total == nil)
        #expect(ping.message == nil)
        _ = try await client.callTool(name: "render", arguments: ["frame": .int(9)])
        #expect(await recorder.events.count == 3)
    }
}
