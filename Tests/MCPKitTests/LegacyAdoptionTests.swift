import Foundation
import Testing
@testable import MCPKit

private let legacyCommand = "/Applications/FilmCraft.app/Contents/MacOS/FilmCraft"

private func legacyIntegration(_ box: Sandbox, commands: [String] = [legacyCommand]) -> MCPIntegration {
    MCPIntegration(name: box.integration.name, displayName: box.integration.displayName,
                   helper: box.integration.helper, arguments: box.integration.arguments,
                   env: box.integration.env, legacyCommands: commands)
}

private func configuration(_ box: Sandbox, agent: AgentID) throws -> URL {
    let definition = try #require(AgentRegistry.load()[agent])
    return MCPEnvironment(home: box.home, bundleURL: box.bundle).expand(definition.config.path)
}

private func configurationText(agent: AgentID, command: String = legacyCommand) -> String {
    if agent == .codex {
        return """
        model = 'user-model'
        [mcp_servers.filmcraft]
        command = '\(command)'
        args = ['old']
        enabled = false
        tool_timeout_sec = 300
        [mcp_servers.filmcraft.env]
        OBSOLETE = 'remove'
        [mcp_servers.filmcraft.tools.search]
        approval_mode = 'prompt'

        """
    }
    return """
    {"model":"user-model","mcpServers":{"filmcraft":{"command":"\(command)","args":["old"],"env":{"OBSOLETE":"remove"},"enabled":false,"preferences":{"allow":["read"]}}}}
    """
}

@Test(arguments: AgentID.allCases)
func legacyEntriesReconcileWithoutALinkAndPreserveUserFields(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    let original = configurationText(agent: agent)
    try box.write(original, to: config)
    let kit = MCPKit(legacyIntegration(box), environment: .init(home: box.home, bundleURL: box.bundle, applicationInstalled: { _ in true }))
    #expect(await kit.status()[agent] == .outdated)
    try await kit.reconcile()
    #expect(await kit.status()[agent] == .connected)
    let definition = try #require(AgentRegistry.load()[agent])
    let data = try Data(contentsOf: config)
    let entry = try #require(try ConfigReader.entry(in: data, definition: definition, name: box.integration.name))
    #expect(entry.command == box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft").path)
    #expect(entry.args == box.integration.arguments)
    #expect(entry.env == box.integration.env)
    #expect(try Data(contentsOf: URL(fileURLWithPath: config.path + ".mcp-kit.bak")) == Data(original.utf8))
    if agent == .codex {
        let output = String(decoding: data, as: UTF8.self)
        #expect(output.contains("model = 'user-model'"))
        #expect(output.contains("enabled = false\ntool_timeout_sec = 300"))
        #expect(output.contains("[mcp_servers.filmcraft.tools.search]\napproval_mode = 'prompt'"))
    } else {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fields = try #require((root["mcpServers"] as? [String: [String: Any]])?["filmcraft"])
        #expect(root["model"] as? String == "user-model")
        #expect(fields["enabled"] as? Bool == false)
        #expect(fields["preferences"] as? NSDictionary == ["allow": ["read"]] as NSDictionary)
    }
}

@Test(arguments: AgentID.allCases)
func disconnectRemovesLegacyEntries(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    let original = configurationText(agent: agent)
    try box.write(original, to: config)
    let kit = MCPKit(legacyIntegration(box), environment: .init(home: box.home, bundleURL: box.bundle, applicationInstalled: { _ in true }))
    try await kit.disconnect(agent)
    #expect(await kit.status()[agent] == .disconnected)
    let definition = try #require(AgentRegistry.load()[agent])
    let data = try Data(contentsOf: config)
    #expect(try ConfigReader.entry(in: data, definition: definition, name: box.integration.name) == nil)
    #expect(String(decoding: data, as: UTF8.self).contains("user-model"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: config.path + ".mcp-kit.bak")) == Data(original.utf8))
}

private struct ReplacingConfigWriter: ConfigWriter {
    let replacement: Data

    func update(_ url: URL, transform: @Sendable (Data?) throws -> Data, verify: @Sendable (Data?) throws -> Bool) throws {
        try replacement.write(to: url)
        try FileWriter().update(url, transform: transform, verify: verify)
    }
}

@Test(arguments: AgentID.allCases, [false, true])
func legacyAdoptionRechecksOwnershipInsideTheTransform(agent: AgentID, reconcile: Bool) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    try box.write(configurationText(agent: agent), to: config)
    let foreignCommand = "/other/FilmCraft.app/Contents/MacOS/FilmCraft"
    let replacement = Data(configurationText(agent: agent, command: foreignCommand).utf8)
    let kit = MCPKit(legacyIntegration(box), environment: .init(home: box.home, bundleURL: box.bundle, applicationInstalled: { _ in true }),
                     writer: ReplacingConfigWriter(replacement: replacement))
    #expect(await kit.status()[agent] == .outdated)
    do {
        if reconcile { try await kit.reconcile() }
        else { try await kit.connect(agent) }
        Issue.record("Expected conflict")
    } catch MCPKitError.conflict(let owner, let command) {
        #expect(owner == agent)
        #expect(command == foreignCommand)
    }
    #expect(await kit.status()[agent] == .conflict)
    #expect(try Data(contentsOf: config) == replacement)
    #expect(!FileManager.default.fileExists(atPath: config.path + ".mcp-kit.bak"))
}

@Test(arguments: AgentID.allCases)
func legacyDisconnectPreservesAnEntryThatBecomesForeign(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    try box.write(configurationText(agent: agent), to: config)
    let replacement = Data(configurationText(agent: agent, command: "/foreign").utf8)
    let kit = MCPKit(legacyIntegration(box), environment: .init(home: box.home, bundleURL: box.bundle, applicationInstalled: { _ in true }),
                     writer: ReplacingConfigWriter(replacement: replacement))
    #expect(await kit.status()[agent] == .outdated)
    try await kit.disconnect(agent)
    #expect(await kit.status()[agent] == .conflict)
    #expect(try Data(contentsOf: config) == replacement)
    #expect(!FileManager.default.fileExists(atPath: config.path + ".mcp-kit.bak"))
}

@Test(arguments: AgentID.allCases, [
    "/other/FilmCraft.app/Contents/MacOS/FilmCraft",
    legacyCommand + "-other",
    legacyCommand + "/",
    "/Applications/FilmCraft.app/Contents/MacOS/../MacOS/FilmCraft",
    legacyCommand.lowercased()
])
func legacyOwnershipRequiresAnExactCommand(agent: AgentID, command: String) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    let original = configurationText(agent: agent, command: command)
    try box.write(original, to: config)
    let kit = MCPKit(legacyIntegration(box), environment: .init(home: box.home, bundleURL: box.bundle, applicationInstalled: { _ in true }))
    #expect(await kit.status()[agent] == .conflict)
    do { try await kit.connect(agent); Issue.record("Expected conflict") }
    catch MCPKitError.conflict(let owner, let existing) {
        #expect(owner == agent)
        #expect(existing == command)
    }
    try await kit.reconcile()
    try await kit.disconnect(agent)
    #expect(await kit.status()[agent] == .conflict)
    #expect(try Data(contentsOf: config) == Data(original.utf8))
    #expect(!FileManager.default.fileExists(atPath: config.path + ".mcp-kit.bak"))
}

@Test(arguments: AgentID.allCases)
func legacyAdoptionUsesTheLatestOwnedEntryAndUserFields(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    try box.write(configurationText(agent: agent), to: config)
    let otherLegacyCommand = "/Applications/Older FilmCraft.app/Contents/MacOS/FilmCraft"
    let replacement = Data(configurationText(agent: agent, command: otherLegacyCommand)
        .replacingOccurrences(of: "user-model", with: "latest-model").utf8)
    let kit = MCPKit(legacyIntegration(box, commands: ["/unused", legacyCommand, otherLegacyCommand]),
                     environment: .init(home: box.home, bundleURL: box.bundle, applicationInstalled: { _ in true }),
                     writer: ReplacingConfigWriter(replacement: replacement))
    #expect(await kit.status()[agent] == .outdated)
    try await kit.connect(agent)
    #expect(await kit.status()[agent] == .connected)
    #expect(try String(contentsOf: config, encoding: .utf8).contains("latest-model"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: config.path + ".mcp-kit.bak")) == replacement)
}

@Test(arguments: AgentID.allCases)
func legacyAdoptionIsOptIn(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    let original = configurationText(agent: agent)
    try box.write(original, to: config)
    #expect(box.integration.legacyCommands.isEmpty)
    let kit = box.kit(desktopInstalled: true)
    #expect(await kit.status()[agent] == .conflict)
    do { try await kit.connect(agent); Issue.record("Expected conflict") }
    catch MCPKitError.conflict(let owner, let command) {
        #expect(owner == agent)
        #expect(command == legacyCommand)
    }
    try await kit.reconcile()
    try await kit.disconnect(agent)
    #expect(try Data(contentsOf: config) == Data(original.utf8))
    #expect(!FileManager.default.fileExists(atPath: config.path + ".mcp-kit.bak"))
}

@Test func originalIntegrationInitializerReferencesRemainSourceCompatible() {
    let make: (String, String, BundledResource, [String], [String: String], [BundledResource]) -> MCPIntegration =
        MCPIntegration.init(name:displayName:helper:arguments:env:skills:)
    let integration = make("filmcraft", "FilmCraft", .bundled("helper"), ["mcp"], ["MODE": "test"], [])
    #expect(integration.name == "filmcraft")
    #expect(integration.arguments == ["mcp"])
    #expect(integration.env == ["MODE": "test"])
    #expect(integration.legacyCommands.isEmpty)
}

@Test(arguments: [AgentID.claudeCode, .codex])
func legacyEntriesRetainSharedResourcesUntilTheLastDisconnect(remainingAgent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    let shared = box.home.appendingPathComponent(".agents/skills")
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: box.home.appendingPathComponent(".claude/skills"), withDestinationURL: shared)
    let integration = MCPIntegration(name: box.integration.name, displayName: box.integration.displayName,
                                     helper: box.integration.helper, arguments: box.integration.arguments,
                                     env: box.integration.env, skills: box.skilledIntegration.skills,
                                     legacyCommands: [legacyCommand])
    let kit = MCPKit(integration, environment: .init(home: box.home, bundleURL: box.bundle))
    let connectedAgent: AgentID = remainingAgent == .claudeCode ? .codex : .claudeCode
    try await kit.connect(connectedAgent)
    let legacyConfig = try configuration(box, agent: remainingAgent)
    let original = configurationText(agent: remainingAgent)
    try box.write(original, to: legacyConfig)
    let skill = shared.appendingPathComponent("filmcraft/SKILL.md")
    let link = box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft")
    try await kit.disconnect(connectedAgent)
    #expect(FileManager.default.fileExists(atPath: skill.path))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    #expect(try Data(contentsOf: legacyConfig) == Data(original.utf8))
    try await kit.disconnect(remainingAgent)
    #expect(!FileManager.default.fileExists(atPath: skill.path))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
}
