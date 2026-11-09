# MCPKitServer 0.3.0 implementation report

Implemented the [approved design](2026-11-09-mcp-kit-iteration-3-design.md). The server validates raw arguments against the same stored schema returned by discovery, before Codable decoding. No parallel constraint validator was introduced. Unknown tools remain protocol `invalidParams` errors.

## Files

| File | Change |
| --- | --- |
| [MCPServer.swift](../../Sources/MCPKitServer/MCPServer.swift) | Annotation overloads, original initializer signatures, structured output, schema validation before invocation |
| [SchemaDecoder.swift](../../Sources/MCPKitServer/SchemaDecoder.swift) | Default `ToolInput.constraints`, constraint application, closed object schemas |
| [SchemaConstraint.swift](../../Sources/MCPKitServer/SchemaConstraint.swift) | Public range, length, and item constraints; declaration diagnostics |
| [SchemaValidator.swift](../../Sources/MCPKitServer/SchemaValidator.swift) | Recursive schema validation with field paths and exact integer-bound comparisons |
| [ServerTests.swift](../../Tests/MCPKitServerTests/ServerTests.swift) | Wire annotations, structured results, original initializer function references |
| [SchemaTests.swift](../../Tests/MCPKitServerTests/SchemaTests.swift) | Closed object schema expectations |
| [StrictValidationTests.swift](../../Tests/MCPKitServerTests/StrictValidationTests.swift) | Unknown keys, nulls, types, required fields, enums, dictionaries, SDK data URLs |
| [ConstraintTests.swift](../../Tests/MCPKitServerTests/ConstraintTests.swift) | Published bounds, inclusive boundary behavior, invalid declarations, Unicode lengths, large integers |
| [README.md](../../README.md) | 0.3.0 API examples and validation contract |
| [CHANGELOG.md](../../CHANGELOG.md) | 0.3.0 release entry |
| [Package.swift](../../Package.swift) | Exclude the changelog from the root-path target to avoid an unhandled-file warning |
| This report | Evidence, decisions, and verification |

`Sources/MCPKit`, its tests, `Package.resolved`, and the Undersong checkout were not changed.

## Design refinements

- Original initializer overloads are retained alongside overloads accepting `annotations:`. Merely adding a defaulted parameter would break 0.2.0 initializer function references; a compile-and-call regression test covers all three original signatures. Omitting annotations still works exactly as before.
- Beyond rejecting unknown constraint keys, construction rejects incompatible field types, negative size bounds, non-finite numeric bounds, and repeated constraints of the same kind. Repetition was unspecified; rejection prevents a later declaration silently replacing an earlier bound.
- String lengths use Unicode code points, matching JSON Schema length semantics. Integer comparisons preserve precision around `2^53` and the native `Int` endpoints.

There are no substantive deviations from the approved behavior.

## swift-sdk 0.12.1 facts

Read directly from the resolved `.build/checkouts/swift-sdk` sources, at revision `a0ae212ebf6eab5f754c3129608bc5557637e605`:

- `Sources/MCP/Server/Tools.swift`: `Tool.Annotations` is a `Hashable`, `Codable`, `Sendable`, nil-literal-expressible struct, not an optional property. Its optional fields are `title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, and `openWorldHint`. Explicit false values survive encoding.
- The same file defines `CallTool.Result` with `content`, `structuredContent: Value?`, `isError`, and `_meta`. The nonthrowing initializer accepting `Value?` is used when returning kit output.
- `Sources/MCP/Client/Client.swift`: the async `callTool` convenience returns only `(content, isError)`. Structured-result tests use `client.send(CallTool.request(...))` and await the full result.
- `Sources/MCP/Base/Value.swift`: integers and doubles are separate cases; `doubleValue` does not coerce integers, while `Double(Value)` accepts both numeric cases. JSON data-URL strings decode as `.data` and re-encode as strings, so string and enum validation handles that representation.

## Acceptance evidence

Read the supplied compatibility `REPORT.md`, both tools-list JSON files, `CompatibilityTests.swift`, and `Legacy.swift`. Their applicable expectations are adapted into the package's permanent tests:

- Annotations and structured content reach a real SDK client through `InMemoryTransport`.
- Unknown root keys, nested schedule keys, array-element keys, and explicit nulls are rejected before forwarding.
- Target minutes, intensity, schedule minutes, BPM, names, tag values, text, and tag counts retain their declared bounds. Additional checks exercise lower/upper boundaries, positive minimum item counts, Unicode, dictionary values, and large integers.
- Unknown-tool behavior deliberately follows the approved protocol-error policy rather than the old probe's tool-error expectation.

The original external probe was not modified or rerun. No app migration or app build is claimed. Its app validator also trims whitespace when checking minimum string length; generic JSON Schema length does not express that business rule. That distinction remains relevant to a later Undersong migration.

## Verification

Compiler: Apple Swift 6.4.2, arm64 macOS. Changes were developed in test-first slices, with failing compile or behavioral tests observed before each implementation change.

Final command:

```sh
env -u MCPKIT_LIVE swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
```

Result: exit 0; 54 tests passed, 1 live smoke test skipped, 0 warnings, 0 errors. The server target reports 22 tests; the integration target reports 33 including the skipped live test. No real user configurations were touched. `git diff --check` passed. All implementation commits have verified signatures.

## Open questions

None for the approved package scope. Version 0.3.0 is recorded in documentation; no tag was created and nothing was pushed.
