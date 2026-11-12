import Foundation
import Testing
@testable import MCPKit

extension Sandbox {
    var skilledIntegration: MCPIntegration {
        MCPIntegration(name: integration.name, displayName: integration.displayName, helper: integration.helper, arguments: integration.arguments, env: integration.env, skills: [.bundled("Skills/filmcraft")])
    }

    func prepareSkills() throws {
        try write("---\nname: filmcraft\ndescription: Film tools\n---\nUse the helper.\n", to: bundle.appendingPathComponent("Skills/filmcraft/SKILL.md"))
        try write("supporting file", to: bundle.appendingPathComponent("Skills/filmcraft/references/guide.md"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }
}

@Test func skillsAreMarkedUpdatedAndRemovedWithTheIntegration() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    let kit = MCPKit(box.skilledIntegration, environment: .init(home: box.home, bundleURL: box.bundle))
    _ = try await kit.connect(.claudeCode)
    let skill = box.home.appendingPathComponent(".claude/skills/filmcraft")
    #expect(try String(contentsOf: skill.appendingPathComponent("references/guide.md"), encoding: .utf8) == "supporting file")
    let marker = skill.appendingPathComponent(".mcp-kit.json")
    let fields = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: String]
    #expect(fields?["bundleID"] == "app.filmcraft")
    #expect(fields?["version"] == "1.0")
    #expect(fields?["digest"]?.count == 64)
    try box.write("{\"bundleID\":\"app.filmcraft\",\"version\":\"0.9\"}", to: marker)
    #expect(await kit.status()[.claudeCode] == .outdated)
    try await kit.reconcile()
    #expect(await kit.status()[.claudeCode] == .connected)
    try await kit.disconnect(.claudeCode)
    #expect(await kit.status()[.claudeCode] == .disconnected)
    #expect(!FileManager.default.fileExists(atPath: skill.path))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft").path)) == nil)
}

@Test func reconcileRepairsBundleMovesWithoutConnectingDisconnectedAgents() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    let original = MCPKit(box.skilledIntegration, environment: .init(home: box.home, bundleURL: box.bundle))
    _ = try await original.connect(.claudeCode)
    let config = box.home.appendingPathComponent(".claude.json")
    let before = try Data(contentsOf: config)
    let moved = box.root.appendingPathComponent("Moved.app")
    try FileManager.default.moveItem(at: box.bundle, to: moved)
    try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let kit = MCPKit(box.skilledIntegration, environment: .init(home: box.home, bundleURL: moved))
    try await kit.reconcile()
    #expect(try Data(contentsOf: config) == before)
    #expect(await kit.status()[.codex] == .disconnected)
    #expect(!FileManager.default.fileExists(atPath: box.home.appendingPathComponent(".codex/config.toml").path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft").path) == moved.appendingPathComponent("Contents/Helpers/filmcraft-cli").path)
}

@Test func sharedSkillsAreCopiedOnceAndKeptUntilTheLastDisconnect() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    let shared = box.home.appendingPathComponent(".agents/skills")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".claude/skills"), withDestinationURL: shared)
    try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let kit = MCPKit(box.skilledIntegration, environment: .init(home: box.home, bundleURL: box.bundle))
    _ = try await kit.connect(.claudeCode)
    let skill = shared.appendingPathComponent("filmcraft")
    let marker = skill.appendingPathComponent(".mcp-kit.json")
    let date = Date(timeIntervalSince1970: 42)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: marker.path)
    _ = try await kit.connect(.codex)
    #expect(try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date == date)
    try await kit.disconnect(.claudeCode)
    #expect(FileManager.default.fileExists(atPath: skill.path))
    #expect(await kit.status()[.codex] == .connected)
    try await kit.disconnect(.codex)
    #expect(!FileManager.default.fileExists(atPath: skill.path))
    try await kit.disconnectAll()
}

@Test func disconnectPreservesForeignEntriesAndUnmarkedSkills() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    let config = box.home.appendingPathComponent(".claude.json")
    let text = "{\"mcpServers\":{\"filmcraft\":{\"command\":\"/other\"}}}"
    try box.write(text, to: config)
    let skill = box.home.appendingPathComponent(".claude/skills/filmcraft/SKILL.md")
    try box.write("user-owned", to: skill)
    let kit = MCPKit(box.skilledIntegration, environment: .init(home: box.home, bundleURL: box.bundle))
    try await kit.disconnect(.claudeCode)
    #expect(try String(contentsOf: config, encoding: .utf8) == text)
    #expect(try String(contentsOf: skill, encoding: .utf8) == "user-owned")
    do { try await kit.connect(.claudeCode, force: true); Issue.record("Expected skill conflict") }
    catch MCPKitError.skillConflict(let url) { #expect(url.lastPathComponent == "filmcraft") }
    #expect(try String(contentsOf: skill, encoding: .utf8) == "user-owned")
}
