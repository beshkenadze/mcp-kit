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

## Completion evidence

- All six tasks completed. No scope deviations; public `start(transport:)` / `stop()` allow the required real-client transport tests. Custom schema decoding must traverse known keyed fields; unsupported probe failures remain fatal even if an input decoder catches them.
- SDK checkout and tag both resolve to `a0ae212ebf6eab5f754c3129608bc5557637e605`.
- `swift build` passed. `MCPKIT_LIVE=0 swift test` passed: 45 executed tests, one live test skipped (33 iteration-1 tests including the skipped smoke, 13 server tests). No warnings from our code or swift-sdk were observed.
- Local subprocess check of the built ExampleHelper passed initialization/instructions, tool discovery, ping, typed rendering, token-scoped progress, protocol-only stdout, and clean EOF exit. It used pipes and no agent configuration.
- The updated live smoke compiles but was not run. No real user configs were changed.
- Manifest dump confirms only MCPKit/MCPKitServer products, ExampleHelper as an executable target depending only on MCPKitServer, and no dependencies for MCPKit. Sources/MCPKit has no diff from iteration 1.
- All implementation commits are signed. No push. No open design questions; live Claude Code/Codex verification remains intentionally unexecuted.

## Review follow-up

Each review regression was observed failing before its fix and passing afterward:

- Duplicate tool names now throw `MCPKitServerError.duplicateTool(name)` before schema construction (`8b93aec`).
- Unknown description keys, including Swift property names that differ from CodingKeys JSON names, now throw `unsupportedInput(tool:reason:)` naming the key (`9c9d1ea`).
- Tool handler errors use `LocalizedError.errorDescription` when present and otherwise `String(describing:)`, including LocalizedError values with a nil description (`4e88abb`).

Final build and full suite passed without warnings. Live smoke remained disabled; Sources/MCPKit is unchanged.
