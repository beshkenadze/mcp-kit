import Foundation
import Testing
@testable import MCPKit

let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("spec/fixtures")

func fixture(_ agent: AgentID, _ name: String, _ side: String, home: URL, ext: String = "json") throws -> Data {
    let url = fixtureRoot.appendingPathComponent("\(agent.rawValue)/\(name)/\(side)/config.\(ext)")
    return Data(try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "$HOME", with: home.path).utf8)
}

@Test(arguments: [AgentID.claudeCode, .claudeDesktop], ["missing", "empty", "foreign", "outdated", "conflict", "broken"])
func jsonGoldenConnections(agent: AgentID, name: String) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let definition = try #require(AgentRegistry.load()[agent])
    let config = MCPEnvironment(home: box.home, bundleURL: box.bundle).expand(definition.config.path)
    try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    var before: Data?
    if name != "missing" {
        before = try fixture(agent, name, "before", home: box.home)
        try box.write(String(decoding: before!, as: UTF8.self), to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    }
    let kit = box.kit(desktopInstalled: true)
    if name == "broken" {
        guard case .unavailable = await kit.status()[agent] else { Issue.record("Broken config must be unavailable"); return }
        await #expect(throws: MCPKitError.self) { try await kit.connect(agent) }
    } else if name == "conflict" {
        #expect(await kit.status()[agent] == .conflict)
        await #expect(throws: MCPKitError.self) { try await kit.connect(agent) }
    } else {
        #expect(await kit.status()[agent] == (name == "outdated" ? .outdated : .disconnected))
        let result = try await kit.connect(agent)
        #expect(result.restartHint == definition.restartHint)
        #expect(await kit.status()[agent] == .connected)
        let actual = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: fixture(agent, name, "after", home: box.home)) as? NSDictionary
        #expect(actual == expected)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft").path) == box.bundle.appendingPathComponent("Contents/Helpers/filmcraft-cli").path)
        if let before {
            #expect(try Data(contentsOf: URL(fileURLWithPath: config.path + ".mcp-kit.bak")) == before)
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        return
    }
    #expect(try Data(contentsOf: config) == fixture(agent, name, "after", home: box.home))
}

@Test func connectionDoesNotCreateAnUndetectedAgentConfig() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    _ = try await box.kit().connect(.claudeCode)
    #expect(!FileManager.default.fileExists(atPath: box.home.appendingPathComponent(".claude.json").path))
}

@Test func forcedConnectionReplacesAConflictingServer() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.write("{\"mcpServers\":{\"filmcraft\":{\"command\":\"other\"}}}", to: box.home.appendingPathComponent(".claude.json"))
    let kit = box.kit()
    _ = try await kit.connect(.claudeCode, force: true)
    #expect(await kit.status()[.claudeCode] == .connected)
}
