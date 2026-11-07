import Foundation
import Testing
@testable import MCPKit

private func helperLink(_ box: Sandbox) -> URL {
    box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft")
}

@Test(arguments: [false, true])
func commentsAndBlankLinesBeforeTheNextTableSurvive(disconnect: Bool) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = box.home.appendingPathComponent(".codex/config.toml")
    let suffix = "\n# history settings\n\n[history]\nmax_bytes = 42\n"
    try box.write("[mcp_servers.filmcraft]\ncommand = \"\(helperLink(box).path)\"\nargs = [\"old\"] # owned line\n" + suffix, to: config)
    if disconnect { try await box.kit().disconnect(.codex) }
    else { try await box.kit().connect(.codex) }
    let text = try String(contentsOf: config, encoding: .utf8)
    #expect(text.hasSuffix(suffix))
    if disconnect { #expect(!text.contains("# owned line")) }
}
