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
