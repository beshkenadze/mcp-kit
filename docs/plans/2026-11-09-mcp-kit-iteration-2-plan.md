# MCPKitServer iteration 2 task plan

Approved scope: [design](2026-11-09-mcp-kit-iteration-2-design.md). Keep iteration 1 behavior unchanged.

## Pinned SDK facts

Resolved `.build/checkouts/swift-sdk` is tag `0.12.1` (see Package.resolved).

- `Sources/MCP/Server/Server.swift`: `Server` is an actor; initializer accepts `instructions` and `capabilities`. Register handlers with `await server.withMethodHandler(Method.self)` and a `@Sendable (Method.Parameters) async throws -> Method.Result`. Start with `start(transport:)`, await `waitUntilCompleted()`, clean up with `stop()`.
- `Sources/MCP/Server/Tools.swift`: `ListTools.Result(tools:nextCursor:)`; `CallTool.Parameters.arguments` is `[String: Value]?`, metadata is `_meta` (initializer label `meta:`). `CallTool.Result(content:isError:)` distinguishes tool failures from thrown protocol errors.
- `MCP.Tool.Content.text(text:annotations:_meta:)` and `.image(data:mimeType:annotations:_meta:)` are the nondeprecated cases. Image data is base64 text. Preserve raw content for other cases.
- `Sources/MCP/Base/Value.swift`: `Value` is Codable/Sendable, with `.object`, `.array`, `.string`, `.int`, `.double`, `.bool`, `.null` and `.data`. Its generic initializer requires Codable, so Encodable-only output uses JSONEncoder directly.
- `Sources/MCP/Base/Transports/InMemoryTransport.swift`: `await InMemoryTransport.createConnectedPair()` returns `(client:server:)`; use real `Client.connect(transport:)` after server start. `Client.listTools()` and `callTool(name:arguments:meta:)` exercise protocol dispatch.
- `Sources/MCP/Base/Transports/StdioTransport.swift`: `StdioTransport()` defaults to stdin/stdout and a no-op logger. `Server` obtains its logger from the transport. No logging bootstrap is needed, and no library prints go to stdout.
- `Sources/MCP/Base/Utilities/Progress.swift`: `ProgressNotification.message(.init(progressToken:progress:total:message:))`, sent by `try await server.notify(...)`. Read `params._meta?.progressToken`; `ProgressToken` is `.string` or `.integer`. Client observes via `onNotification(ProgressNotification.self)`.

## Tasks (each behavior starts with a failing public-interface test)

1. Add MCPKitServer product/target and re-export. Implement no-input declarations, builder, in-memory server lifecycle, discovery, instructions, and text calls.
2. Add schema recording and typed decoding, expanding one behavior at a time: primitives/descriptions/optional; nested objects and collections; enums/empty objects; unsupported roots/types/recursion fail during construction. Verify schemas through Client.listTools.
3. Verify argument failures, handler failures, unknown names, JSON/image/raw content outputs, and all handler overloads.
4. Verify token-scoped progress (string/integer tokens and no-token no-op).
5. Add ExampleHelper executable target and stdio lifetime. Verify its protocol over pipes without touching configs. Prepare an opt-in MCPKIT_LIVE smoke test using the built helper; never run it here.
6. Document target dependencies, helper embedding/signing, skill paths, complete helper example; run swift build and swift test, inspect warnings and iteration-1 diff, commit.

Use Swift Testing and Swift 6 concurrency throughout. Tests clean up their own temporary files with normal filesystem deletion. Shell deletion uses trash only. Signed conventional commits; no push. Live smoke stays disabled even if the invoking environment sets MCPKIT_LIVE.
