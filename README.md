# MCPKit

A dependency-free Swift 6 actor for connecting a bundled stdio MCP helper and skills to Claude Code, Claude Desktop, and Codex. Requires macOS 14 or later and an app without App Sandbox.

```swift
import MCPKit

let integration = MCPIntegration(
    name: "filmcraft",
    displayName: "FilmCraft",
    helper: .bundled("Contents/Helpers/filmcraft-cli"),
    arguments: ["mcp"],
    skills: [.bundled("Skills/filmcraft")]
)
let kit = MCPKit(integration)

let statuses = await kit.status()
let result = try await kit.connect(.codex)
try await kit.reconcile()
try await kit.disconnect(.claudeCode)
try await kit.disconnectAll()
```

Bundled paths are relative to the app bundle root. Ship an executable helper, a `CFBundleIdentifier` and `CFBundleShortVersionString` in `Contents/Info.plist`, and a `SKILL.md` in each supplied skill folder. `env:` accepts explicit string environment variables. The helper should resolve its executable with `realpath`, because its invocation path is a symlink.

The stable helper path is `~/Library/Application Support/<bundle-id>/mcp-kit/bin/<name>`. A server entry belongs to this integration only when its command equals that path. The kit owns `command`, `args`, `env`, and `type` where the agent template includes it; updates preserve all other user fields and subtables. `connect(_:force:)` replaces a foreign entry only with `force: true`; force never takes over an unmarked or foreign skill folder. Connecting an undetected agent throws `MCPKitError.agentNotFound`. `ConnectResult.restartHint` supplies the registry's restart guidance.

`status()` compares only owned fields and returns `agentNotFound`, `disconnected`, `connected`, `outdated`, `conflict`, or `unavailable(reason)`. Missing installed skills and older owned markers are outdated. A conflicting skill marker is unavailable and `connect` throws `skillConflict`. `reconcile()` repoints the helper only when a link already exists or an agent has an owned entry. It attempts every outdated integration before throwing the first error; disconnected agents stay disconnected. Call it when the app launches.

Config writes resolve symlinks and reread the target, preserve unrelated JSON values or TOML text, save `<target>.mcp-kit.bak`, preserve existing permissions (new files use `0600`), and rename a temporary file beside the target into place. Config symlinks stay intact. TOML edits preserve blank lines and comments between tables. Verification retries once using the latest file. There is no cross-process lock or rollback; a later `connect` or `reconcile` completes partial work. Unreadable files are left untouched, and TOML inline/dotted layouts for this server's owned fields throw `unsupportedLayout`. The TOML reader is deliberately scoped to stdio tables; unfamiliar syntax fails closed.

Skills carry `.mcp-kit.json` with the owning bundle ID and app version. Shared directories, including directory symlinks, are deduplicated. Disconnect removes only marked skills and retains shared skills while another agent still has an owned entry. An unreadable other config is treated as possibly connected: disconnect succeeds and retains its potentially shared skills and the helper link. No agent CLI is invoked by the library. To support another write mechanism, inject a `ConfigWriter`; its synchronous `update` operation must reread, transform, atomically write, verify, and retry once before throwing.

Call `disconnectAll()` from the app's uninstall flow **before deleting the app**. Otherwise the helper symlink will dangle. The kit does not watch files, restart agents, or provide UI.

Tests use `MCPEnvironment(home:bundleURL:)` with temporary directories. An injected environment detects no installed Desktop app unless its `applicationInstalled` closure says otherwise; `.live` uses Launch Services. Run `swift build` and `swift test`. The registry and verified source links are in [spec/README.md](spec/README.md); portable before/after fixtures are in `spec/fixtures`.

The live registration smoke test is disabled by default. Only `MCPKIT_LIVE=1 swift test --filter liveSmokeRegistersAHelperAndChecksAgentCLIs` opts in to real Claude Code/Codex config writes and read-only `claude mcp get` / `codex mcp get` checks. It uses a uniquely named temporary helper with no skills and disconnects on completion or failure. It checks registration, not an MCP protocol handshake. **It was not run during implementation.**
