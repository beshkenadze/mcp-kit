# Agent registry and fixtures

Verified on 2026-11-07, before implementation. `agents.json` is the runtime source of agent paths, detection rules, configuration keys, entry templates, skill locations, and restart hints. SwiftPM ships that file directly as a resource; there is no second registry copy.

## Verified facts

| Agent | Verified user configuration |
| --- | --- |
| Claude Code | User scope is the top-level `mcpServers` object in `~/.claude.json`, distinct from project-local entries under `projects`. A stdio entry has `type: "stdio"`, `command`, `args` (string array), and `env` (string dictionary). Personal skills live at `~/.claude/skills/<name>/SKILL.md`. |
| Claude Desktop | macOS config is `~/Library/Application Support/Claude/claude_desktop_config.json`, under `mcpServers`. The portable stdio shape is `command`, `args`, `env`. **`type: "stdio"` is accepted**, rather than rejected: Anthropic's current Claude Code documentation explicitly includes it in its Desktop example. The kit omits this optional key, as the approved design requests. Desktop must restart after config changes. Its macOS bundle identifier is `com.anthropic.claudefordesktop`. |
| Codex | User config is `~/.codex/config.toml`. A stdio server uses `[mcp_servers.<name>]` with `command` and `args`; explicit variables go under `[mcp_servers.<name>.env]` as string values. No transport discriminator is necessary. User skills live at `$HOME/.agents/skills/<name>/SKILL.md`. |

Sources:

- [Claude Code MCP scopes and JSON configuration](https://code.claude.com/docs/en/mcp#mcp-installation-scopes), including the [stdio JSON and Desktop examples](https://code.claude.com/docs/en/mcp#use-claude-code-as-an-mcp-server).
- [Claude Code personal skill locations](https://code.claude.com/docs/en/skills#choose-where-skills-load).
- [Official MCP Desktop setup guide](https://modelcontextprotocol.io/docs/develop/connect-local-servers): config location, stdio command/args/env, restart requirement.
- [Claude Desktop distribution](https://claude.ai/download). Bundle identifier additionally checked directly in `/Applications/Claude.app/Contents/Info.plist` (`CFBundleIdentifier`), installed version 4.16336.0. No user configuration was read.
- [Official Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), especially “config.toml examples” and stdio settings.
- [Official Codex skill locations](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills).

No required design changes follow from these facts. Desktop's optional `type` support clarifies the design's omission; the emitted entry stays unchanged.

## Golden fixture contract

`fixtures/<agent>/<case>/{before,after}` contains complete config files. Missing-file cases use `.absent` instead of a config in `before`. `$HOME` is replaced with the isolated test home. The example integration is `filmcraft`, bundle ID `app.filmcraft`, arguments `["mcp"]`, environment `{"MODE":"test"}`. JSON is compared semantically; TOML is compared byte-for-byte. Conflict and broken-file cases leave the input unchanged. TOML comments are a Codex-only case.
