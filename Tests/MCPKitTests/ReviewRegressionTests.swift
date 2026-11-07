import Foundation
import Testing
@testable import MCPKit

private func helperLink(_ box: Sandbox) -> URL {
    box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft")
}

@Test(arguments: [AgentID.codex, .claudeCode])
func symlinkedConfigsKeepTheirLinksAndWriteBesideTheTarget(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let definition = try #require(AgentRegistry.load()[agent])
    let config = MCPEnvironment(home: box.home, bundleURL: box.bundle).expand(definition.config.path)
    let real = box.root.appendingPathComponent("dotfiles/config")
    let before = agent == .codex ? "model = \"x\"\n" : "{\"theme\":\"dark\"}"
    try box.write(before, to: real)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    let intermediate = box.root.appendingPathComponent("config-link")
    try FileManager.default.createSymbolicLink(atPath: intermediate.path, withDestinationPath: "dotfiles/config")
    try FileManager.default.createSymbolicLink(at: config, withDestinationURL: intermediate)
    let kit = box.kit()
    try await kit.connect(agent)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: config.path)) != nil)
    #expect(await kit.status()[agent] == .connected)
    #expect(try String(contentsOf: real, encoding: .utf8).contains("filmcraft"))
    #expect(try String(contentsOfFile: real.path + ".mcp-kit.bak", encoding: .utf8) == before)
    #expect(!FileManager.default.fileExists(atPath: config.path + ".mcp-kit.bak"))
    #expect(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int == 0o640)
    try await kit.disconnect(agent)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: config.path)) != nil)
    #expect(!String(decoding: try Data(contentsOf: real), as: UTF8.self).contains("filmcraft"))
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
