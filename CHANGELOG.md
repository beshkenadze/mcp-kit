# Changelog

## 0.4.0 — 2026-11-09

- Add `MCPIntegration.legacyCommands: [String] = []` for exact command paths written by an app's previous installer. Preserve the original initializer and default ownership behavior.
- Report legacy entries as outdated, adopt them through `connect()` without force or automatically through `reconcile()`, and remove them through `disconnect()`. Preserve user fields and TOML subtables during adoption, and retain shared resources while other owned entries remain.
- Check ownership inside the config writer's transform using its current input bytes. A foreign replacement remains untouched and reports a conflict during connection or reconciliation.
- Ignore empty legacy command strings; entries without a command remain foreign.
- Preflight config and skill failures before creating resources. Forced connections replace foreign JSON and TOML entries completely; owned entries retain user fields and subtables.
- Preserve config bytes and backups when the managed entry already matches, including its transport type. Disconnect does not recreate configs that disappear before writing.
- Track skill content with SHA-256 digests and repair changed bundled or installed content even at the same app version. Older versions remain outdated; markers without a digest receive a one-time upgrade.
- Render TOML managed fields from one field list, including transport type, and reuse bundle metadata and the agent registry throughout each operation.
- Require `ToolOutput.structured` values to encode as JSON objects; arrays, scalars, and null throw `MCPKitServerError.invalidStructuredOutput`.
- Add `ToolInput.inputSchema()` and `ToolInput.validate(_:)` for schema access and argument validation outside a server, sharing the server's schema source, validator, and decoding errors.
- Omit `minLength` and `minItems` from published schemas when `.length` or `.items` has a zero lower bound. Positive lower bounds, upper bounds, validation, and duplicate-constraint rejection are unchanged.
- Cover all three agents with Swift Testing, including ownership races, exact matching, opt-in compatibility, and shared-resource cleanup under Swift 6 strict concurrency.

## 0.3.0 — 2026-11-09

- Add `annotations: MCP.Tool.Annotations` to every `Tool` handler shape, preserving explicit false hints and titles in discovery. Keep all 0.2.0 initializer signatures available.
- Add `ToolOutput.structured(_:text:)` with `structuredContent` and a custom or automatically encoded JSON text fallback. Existing output factories retain their behavior.
- Add `ToolInput.constraints` and inclusive `.range`, `.length`, and `.items` schema constraints. Invalid declarations fail during server construction.
- Validate raw arguments against the exact published schema before Codable decoding. Enforce types, required fields, enums, bounds, and closed object keys recursively; dictionaries retain arbitrary keys with validated values.
- Reject explicit nulls, including optional fields; callers must omit optional values instead. Return actionable tool errors with field paths. Unknown tools remain protocol `invalidParams` errors.
- Leave `MCPKit` agent integration unchanged. Retain Swift 6 strict concurrency and swift-sdk 0.12.1 compatibility.
