import Foundation
import Testing
@testable import MCPKit

private func helperLink(_ box: Sandbox) -> URL {
    box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft")
}

@Test(arguments: AgentID.allCases)
func connectingAnUndetectedAgentReportsFailure(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    do { try await box.kit().connect(agent); Issue.record("Expected agentNotFound") }
    catch MCPKitError.agentNotFound(let missing) { #expect(missing == agent) }
    #expect(!FileManager.default.fileExists(atPath: helperLink(box).path))
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

@Test(arguments: [AgentID.claudeDesktop, .claudeCode])
func unreadableOtherConfigsDoNotBlockDisconnectAndRetainPossibleSharedResources(other: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    let shared = box.home.appendingPathComponent(".agents/skills")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".claude/skills"), withDestinationURL: shared)
    try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let kit = MCPKit(box.skilledIntegration, environment: .init(home: box.home, bundleURL: box.bundle, applicationInstalled: { _ in true }))
    try await kit.connect(.codex)
    let definition = try #require(AgentRegistry.load()[other])
    let broken = MCPEnvironment(home: box.home, bundleURL: box.bundle).expand(definition.config.path)
    try box.write("{ broken", to: broken)
    try await kit.disconnect(.codex)
    #expect(await kit.status()[.codex] == .disconnected)
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: helperLink(box).path)) != nil)
    #expect(FileManager.default.fileExists(atPath: shared.appendingPathComponent("filmcraft").path) == (other == .claudeCode))
    #expect(try String(contentsOf: broken, encoding: .utf8) == "{ broken")
}

@Test func reconcileRepairsRemainingOutdatedAgentsBeforeThrowingTheFirstFailure() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    try box.write("{\"mcpServers\":{\"filmcraft\":{\"command\":\"\(helperLink(box).path)\",\"args\":[\"old\"]}}}", to: box.home.appendingPathComponent(".claude.json"))
    try box.write("[mcp_servers.filmcraft]\ncommand = \"\(helperLink(box).path)\"\nargs = [\"old\"]\n", to: box.home.appendingPathComponent(".codex/config.toml"))
    let conflict = box.home.appendingPathComponent(".claude/skills/filmcraft")
    try box.write("user skill", to: conflict.appendingPathComponent("SKILL.md"))
    let kit = MCPKit(box.skilledIntegration, environment: .init(home: box.home, bundleURL: box.bundle))
    #expect(await kit.status()[.claudeCode] == .outdated)
    #expect(await kit.status()[.codex] == .outdated)
    do { try await kit.reconcile(); Issue.record("Expected the first agent's skill conflict") }
    catch MCPKitError.skillConflict(let url) { #expect(url.path == conflict.resolvingSymlinksInPath().path) }
    #expect(await kit.status()[.codex] == .connected)
    #expect(try String(contentsOf: conflict.appendingPathComponent("SKILL.md"), encoding: .utf8) == "user skill")
}
