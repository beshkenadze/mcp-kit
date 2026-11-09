# Changelog

## 0.3.0 — 2026-11-09

- Add `annotations: MCP.Tool.Annotations` to every `Tool` handler shape, preserving explicit false hints and titles in discovery. Keep all 0.2.0 initializer signatures available.
- Add `ToolOutput.structured(_:text:)` with `structuredContent` and a custom or automatically encoded JSON text fallback. Existing output factories retain their behavior.
- Add `ToolInput.constraints` and inclusive `.range`, `.length`, and `.items` schema constraints. Invalid declarations fail during server construction.
- Validate raw arguments against the exact published schema before Codable decoding. Enforce types, required fields, enums, bounds, and closed object keys recursively; dictionaries retain arbitrary keys with validated values.
- Reject explicit nulls, including optional fields; callers must omit optional values instead. Return actionable tool errors with field paths. Unknown tools remain protocol `invalidParams` errors.
- Leave `MCPKit` agent integration unchanged. Retain Swift 6 strict concurrency and swift-sdk 0.12.1 compatibility.
