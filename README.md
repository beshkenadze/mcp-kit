# MCPKit

Swift 6 tools for shipping a bundled stdio MCP helper and connecting it, with skills, to Claude Code, Claude Desktop, and Codex. Requires macOS 14 or later; the integration app runs without App Sandbox.

Version 0.4.0 adds opt-in adoption of legacy agent entries through `MCPIntegration.legacyCommands`, public input schema access and validation, and fixes for registration and skill freshness. It preserves the 0.3.0 public API. See [CHANGELOG.md](CHANGELOG.md).

| Product | Add to target | Purpose |
|---|---|---|
| `MCPKit` | Your application | Register/disconnect the helper and install skills. No external dependencies. |
| `MCPKitServer` | Your command-line helper | Declare tools, derive input schemas, decode calls, report progress, and serve stdio. Re-exports the official `MCP` SDK. |

The package uses [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) `from: "0.12.1"`; the checked-in resolution is `0.12.1`. Only `MCPKitServer` depends on its `MCP` product. `ExampleHelper` is an executable target for the example and smoke checks, with only `MCPKitServer` as its dependency; it is not declared as a package product.

## Complete helper

The following is also [Sources/ExampleHelper/ExampleHelper.swift](Sources/ExampleHelper/ExampleHelper.swift). Add `MCPKitServer` to your helper target and use a single import:

```swift
import MCPKitServer

struct RenderArgs: ToolInput {
    let frame: Int
    let format: Format?
    static let descriptions = ["frame": "Frame number", "format": "Output format"]
}

enum Format: String, ToolInputEnum { case png, jpeg }

@main struct Helper {
    static func main() async throws {
        try await MCPServer(name: "filmcraft", version: "1.0", instructions: "Edits FilmCraft projects.") {
            Tool("render_frame", "Render one frame", input: RenderArgs.self) { args, context in
                await context.progress(0.5, total: 1, message: "Rendering")
                return .text("Rendered \(args.frame)")
            }
            Tool("ping", "Health check") { _ in .text("pong") }
        }.runStdio()
    }
}
```

`Tool` supports handlers taking a context alone, typed input alone, or typed input and context. `ToolInput` is `Decodable & Sendable`; `descriptions` defaults to empty. Schemas cover strings, URI-formatted URLs, signed/unsigned integers through 64 bits, floats, booleans, arrays, string-keyed dictionaries, nested objects, and string-backed `ToolInputEnum` cases. Keys decoded with `decodeIfPresent` are optional. Empty input is an object. Unsupported shapes, single-value roots, and recursive inputs throw `MCPKitServerError.unsupportedInput(tool:reason:)` when constructing the server. Schema recording runs your decoder with representative values; custom decoders must permit that traversal and use known keyed fields (or the supported collection types).

Tool names must be unique; duplicates throw `MCPKitServerError.duplicateTool(name)` during construction. Keys in `descriptions` must match decoded JSON field names (including any `CodingKeys` renaming); unknown keys throw `unsupportedInput(tool:reason:)` naming the key.

Return `.text("...")`, `try .json(encodableValue)` (JSON text), `try .structured(encodableValue, text: "...")`, `.image(data, mimeType: "image/png")`, or `.content([MCP.Tool.Content])`. Structured output requires an encoded JSON object; arrays, scalars, and null throw `MCPKitServerError.invalidStructuredOutput`. It sends the object as `structuredContent` and includes one text content block. Omit `text:` to use JSON from the same encoding; an explicit empty string stays empty. `.json` remains text-only, and `.content` preserves the supplied content blocks.

All three handler shapes accept `annotations: MCP.Tool.Annotations`. Omit it for empty SDK annotations, or use `.init(title:readOnlyHint:destructiveHint:idempotentHint:openWorldHint:)`; explicit `false` hints survive discovery. The original initializer signatures also remain available, including for function references.

## Constraints and strict input

Declare inclusive constraints on each `ToolInput` type using decoded JSON field names:

```swift
struct SearchArgs: ToolInput {
    let query: String
    let limit: Int?
    let categories: [String]?
    static let descriptions = ["query": "Search text"]
    static let constraints: [String: [SchemaConstraint]] = [
        "query": [.length(1...80)],
        "limit": [.range(1...100)],
        "categories": [.items(0...24)]
    ]
}

let server = try MCPServer(name: "search", version: "1") {
    Tool("search", "Search the local catalog", input: SearchArgs.self, annotations: .init(
        title: "Search catalog", readOnlyHint: true, destructiveHint: false, openWorldHint: false
    )) { args in
        try .structured(["limit": args.limit ?? 10], text: "Search ready")
    }
}
```

`constraints` defaults to empty. `.range(ClosedRange<Double>)` adds `minimum`/`maximum` to integer or number fields; `.length(ClosedRange<Int>)` adds `minLength`/`maxLength` to strings; `.items(ClosedRange<Int>)` adds `minItems`/`maxItems` to arrays. Zero lower bounds omit `minLength` and `minItems`, using the JSON Schema default with the same validation behavior. String lengths count Unicode code points. Put nested constraints on the nested `ToolInput` type, including array and dictionary value types. Use `CodingKeys` names rather than Swift property names; dotted paths are not supported. Unknown keys, constraints on incompatible field types, negative size bounds, non-finite numeric bounds, and repeated constraints of the same kind throw `unsupportedInput(tool:reason:)` during server construction.

The schema sent by `tools/list` is the single validation source. Before Codable decoding or invoking a handler, the server checks raw arguments against that exact stored schema: types, required fields, unknown keys, enums, and every declared bound. All recorded objects, including empty inputs, have `additionalProperties: false`. String-keyed dictionaries accept arbitrary keys and validate each value against their value schema. Explicit `null` is rejected at every input value, including optional fields and collection elements; omit an optional field instead. Omitted arguments are treated as an empty object.

Any `ToolInput` type also exposes its schema and validates arguments without starting a server:

```swift
let schema = try SearchArgs.inputSchema()
try SearchArgs.validate(["query": .string("swift"), "limit": .int(10)])
```

These methods use the same schema source, validator, and Codable decoding as the server. `validate` throws the same argument errors, including decoding errors such as an integer outside its Swift type's range, and does not invoke a tool handler.

Invalid arguments return `isError: true` with a field path such as `$.schedule.start_minute` or `$.tags[0].value`. Handler and decoding errors use `LocalizedError.errorDescription` when present, otherwise `String(describing: error)`. An unknown tool remains a protocol `invalidParams` error (`-32602`). Progress is emitted only when that call supplies `_meta.progressToken`.

`runStdio()` starts the SDK's `StdioTransport`, waits until its input closes or the task is cancelled, and stops the server. Keep stdout exclusively for protocol traffic; write diagnostics to stderr. Progress-send failures are logged to stderr. The raw SDK remains available through the re-export, including `MCP.Tool.Content`. For embedded transports and tests, `start(transport:)` and `stop()` manage the same server.

## Embed and sign the helper

1. Create a macOS command-line executable target in your Xcode app project, add `MCPKitServer` to that target, and put the helper code there. Add `MCPKit` to the app target.
2. Add the helper target to the app's **Build Phases → Target Dependencies**.
3. Add a **Copy Files** build phase to the app. Set **Destination: Wrapper**, **Subpath: Contents/Helpers**, add the helper executable from Products, and enable **Code Sign On Copy**. Name the executable `filmcraft-cli` to match the app declaration below.
4. Use your signing team for both targets and enable **Hardened Runtime** (`ENABLE_HARDENED_RUNTIME = YES`) for the helper and app. Sign the embedded helper before signing the enclosing app. For a manual release pipeline, the inner signing command is `codesign --force --options runtime --timestamp --sign "Developer ID Application: Your Team (TEAMID)" FilmCraft.app/Contents/Helpers/filmcraft-cli`; then sign the outer app with the same identity and runtime option. Verify the completed bundle with `codesign --verify --deep --strict FilmCraft.app` and inspect the helper's runtime flag with `codesign -d --verbose=4 FilmCraft.app/Contents/Helpers/filmcraft-cli`.

Ship `CFBundleIdentifier` and `CFBundleShortVersionString` in the app's `Contents/Info.plist`. Bundled paths below are relative to the app bundle root. If a helper needs its own location, resolve its executable with `realpath`, because agents invoke it through a symlink. This example needs no bundle-relative assets or command-line arguments.

## Connect from the app

```swift
import MCPKit

let integration = MCPIntegration(
    name: "filmcraft",
    displayName: "FilmCraft",
    helper: .bundled("Contents/Helpers/filmcraft-cli"),
    skills: [.bundled("Skills/filmcraft")]
)
let kit = MCPKit(integration)

let statuses = await kit.status()
let result = try await kit.connect(.codex)
try await kit.reconcile()
try await kit.disconnect(.claudeCode)
try await kit.disconnectAll()
```

Use `arguments:` only if your helper expects them; `ExampleHelper` starts serving immediately. `env:` accepts explicit string environment variables.

Keep the bundled skill at `Skills/filmcraft/SKILL.md` (Copy Files destination Wrapper, subpath `Skills`). If you instead copy skills into the app's resources, declare `.bundled("Contents/Resources/Skills/filmcraft")`. MCPKit installs marked copies under `~/.claude/skills/filmcraft` for Claude Code and `~/.agents/skills/filmcraft` for Codex. Claude Desktop skills are managed in the cloud and are not installed locally by MCPKit.

The stable helper path is `~/Library/Application Support/<bundle-id>/mcp-kit/bin/<name>`. A server entry belongs to this integration when its command equals that path or one of its declared `legacyCommands`. The kit owns `command`, `args`, `env`, and `type` where the agent template includes it; updates to owned entries preserve all other user fields and subtables. `connect(_:force:)` replaces a foreign entry completely only with `force: true`, removing its previous fields and subtables; force never takes over an unmarked or foreign skill folder. Connecting an undetected agent throws `MCPKitError.agentNotFound`. Connection preflight reads and transforms the config and validates skill sources and ownership before creating the helper link, writing the config, or installing skills. `ConnectResult.restartHint` supplies the registry's restart guidance.

### Adopt legacy entries

If an earlier installer registered a direct executable path, declare the exact command paths that installer wrote:

```swift
let integration = MCPIntegration(
    name: "filmcraft",
    displayName: "FilmCraft",
    helper: .bundled("Contents/Helpers/filmcraft-cli"),
    legacyCommands: ["/Applications/FilmCraft.app/Contents/MacOS/FilmCraft"]
)
let kit = MCPKit(integration)
try await kit.reconcile()
```

`legacyCommands:` defaults to `[]`; empty strings are ignored, and an entry without a command is never owned. Matching compares the command string exactly, without path normalization, symlink resolution, or filename/suffix guesses. List only paths previously written by your app; a matching command grants ownership regardless of the entry's arguments or environment.

`status()` reports a legacy entry as `outdated`. `connect()` adopts it without `force`, and `reconcile()` adopts it even before the stable helper link exists. Adoption replaces the owned fields and preserves user fields and TOML subtables. `disconnect()` also removes legacy entries, retaining shared resources while another owned entry remains.

Ownership is checked again inside the writer's `transform` against its current input bytes. If a legacy entry becomes foreign after `status()`, `connect()` or `reconcile()` throws `MCPKitError.conflict` and preserves that entry. Apps can rely on the kit's registry and writer instead of maintaining agent config paths or comparing file snapshots themselves.

`status()` compares only owned fields and returns `agentNotFound`, `disconnected`, `connected`, `outdated`, `conflict`, or `unavailable(reason)`. Missing installed skills, older owned markers, and installed or bundled content changes are outdated. Markers without a content digest are outdated once and gain a digest during repair. A conflicting skill marker is unavailable and `connect` throws `skillConflict`. `reconcile()` repoints the helper only when a link already exists or an agent has an owned entry. It attempts every outdated integration before throwing the first error; disconnected agents stay disconnected. Call it when the app launches. Each operation resolves bundle metadata and the agent registry once, including operations spanning multiple agents.

Config writes resolve symlinks and reread the target, preserve unrelated JSON values or TOML text, save `<target>.mcp-kit.bak`, preserve existing permissions (new files use `0600`), and rename a temporary file beside the target into place. When an entry already matches, connecting leaves the config byte-identical and neither creates nor updates its backup. Disconnect does not recreate a config that disappears before the writer reads it. Config symlinks stay intact. TOML edits preserve blank lines and comments between tables. Verification retries once using the latest file. There is no cross-process lock or rollback; a later `connect` or `reconcile` completes partial work. Unreadable files are left untouched, and TOML inline/dotted layouts for this server's owned fields throw `unsupportedLayout`. The TOML reader is deliberately scoped to stdio tables; unfamiliar syntax fails closed.

Skills carry `.mcp-kit.json` with the owning bundle ID, app version, and SHA-256 content digest. Freshness compares bundled and installed contents, including supporting files, with that digest. Shared directories, including directory symlinks, are deduplicated. Disconnect removes only marked skills and retains shared skills while another agent still has an owned entry. An unreadable other config is treated as possibly connected: disconnect succeeds and retains its potentially shared skills and the helper link. No agent CLI is invoked by the library. To support another write mechanism, inject a `ConfigWriter`; its synchronous `update` operation must reread, transform, atomically write, verify, and retry once before throwing. Skip writes when unchanged input verifies, including missing input transformed to empty data.

Call `disconnectAll()` from the app's uninstall flow **before deleting the app**. Otherwise the helper symlink will dangle. The kit does not watch files, restart agents, or provide UI.

## Verification

Run `swift build` and `swift test`. Registration tests use `MCPEnvironment(home:bundleURL:)` with temporary directories; an injected environment detects no installed Desktop app unless its `applicationInstalled` closure says otherwise. `.live` uses Launch Services. Server tests use a real SDK `Client` and `InMemoryTransport`, including discovery annotations, structured results, schemas, strict input validation, constraint boundaries, errors, content, and progress. Structured-result checks use `client.send(CallTool.request(...))` to inspect the full SDK `CallTool.Result`. The registry and verified source links are in [spec/README.md](spec/README.md); portable before/after fixtures are in `spec/fixtures`.

The live smoke test is disabled by default. After building, `MCPKIT_LIVE=1 swift test --filter liveSmokeRegistersAHelperAndChecksAgentCLIs` opts in to **real Claude Code/Codex config writes**. It copies the built `ExampleHelper` into a temporary app, registers a unique server through `MCPKit`, requires `claude mcp get` to report **Connected**, verifies `codex mcp get` shows the helper, then disconnects on completion or failure. It installs no skills. **This live test was not run during implementation.**
