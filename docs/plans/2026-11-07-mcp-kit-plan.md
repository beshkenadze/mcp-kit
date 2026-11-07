# MCPKit iteration 1 implementation plan

Follow the approved design at `2026-11-07-mcp-kit-design.md`. Facts and sources are recorded in `spec/README.md` before code.

Each numbered task uses a failing Swift Testing test, an observed red run, the smallest implementation, a green run, and its own signed conventional commit. Additional regression cases follow the same red/green cycle within the relevant task.

1. Add the Swift 6 package, resource-backed agent registry, public value types, injectable environment, actor, and agent detection.
2. Implement JSON reading/status and safe, owned stdio connections; cover Claude Code/Desktop golden fixtures, backup, mode preservation, and conflict protection.
3. Implement narrow TOML reading and table replacement; cover Codex golden fixtures, preserved comments/unrelated bytes, and rejected unsupported layouts.
4. Install marked skills, report stale integrations, reconcile bundle moves, and disconnect with shared-skill/link ownership rules.
5. Verify retry-on-overwrite and error behavior, add the opt-in live smoke test (never run here), and document embedding/uninstall behavior. Run `swift build` and `swift test` with zero warnings and inspect the final diff.

All automated tests inject a temporary home and bundle. No agent CLI writes configuration. No real configs or skill directories are accessed. No pushes.
