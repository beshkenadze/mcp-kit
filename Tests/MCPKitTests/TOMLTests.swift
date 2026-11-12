import Foundation
import Testing
@testable import MCPKit

@Test(arguments: ["missing", "empty", "foreign", "outdated", "conflict", "comments", "broken"])
func tomlGoldenConnections(name: String) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = box.home.appendingPathComponent(".codex/config.toml")
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    if name != "missing" {
        try fixture(.codex, name, "before", home: box.home, ext: "toml").write(to: config)
    }
    let kit = box.kit()
    if name == "broken" {
        guard case .unavailable = await kit.status()[.codex] else { Issue.record("Broken TOML must be unavailable"); return }
        await #expect(throws: MCPKitError.self) { try await kit.connect(.codex) }
    } else if name == "conflict" {
        #expect(await kit.status()[.codex] == .conflict)
        await #expect(throws: MCPKitError.self) { try await kit.connect(.codex) }
    } else {
        #expect(await kit.status()[.codex] == (name == "outdated" ? .outdated : .disconnected))
        _ = try await kit.connect(.codex)
        #expect(await kit.status()[.codex] == .connected)
    }
    #expect(try Data(contentsOf: config) == fixture(.codex, name, "after", home: box.home, ext: "toml"))
}

@Test(arguments: [
    "mcp_servers.filmcraft.command = '/other'\n",
    "[mcp_servers]\nfilmcraft = { command = '/other' }\n",
    "mcp_servers = { filmcraft = { command = '/other' } }\n",
    "[mcp_servers.filmcraft]\ncommand = '/other'\nenv = { MODE = 'old' }\n",
    "[mcp_servers.filmcraft]\ncommand = '/other'\nenv.MODE = 'old'\n"
])
func unsupportedTOMLLayoutsStayUntouched(text: String) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = box.home.appendingPathComponent(".codex/config.toml")
    try box.write(text, to: config)
    do { try await box.kit().connect(.codex, force: true); Issue.record("Expected unsupported layout") }
    catch MCPKitError.unsupportedLayout(let agent, let url) { #expect(agent == .codex); #expect(url == config) }
    #expect(try String(contentsOf: config, encoding: .utf8) == text)
}

@Test(arguments: [
    "model = not-a-value\n", "model = 'unterminated\n", "[history\n",
    "model = 'one'\nmodel = 'two'\n", "args = [1, 2\n", "x = { a = 1, a = 2 }\n",
    "model = 'one'\n[model.options]\nenabled = true\n",
    "model.options = true\nmodel = 'one'\n"
])
func malformedTOMLPreservesTheOriginal(text: String) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = box.home.appendingPathComponent(".codex/config.toml")
    try box.write(text, to: config)
    do { try await box.kit().connect(.codex); Issue.record("Expected unreadable config") }
    catch MCPKitError.unreadableConfig(let agent, _, _) { #expect(agent == .codex) }
    #expect(try String(contentsOf: config, encoding: .utf8) == text)
}

@Test func tomlQuotedKeysAndMultilineValuesRoundTrip() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let prefix = "# Preserve Unicode and CRLF\r\nmodel = '''line one\n[mcp_servers.filmcraft]\nline two'''\r\n\r\n[features]\r\nitems = [1, { x = true }] # keep\r\n"
    let config = box.home.appendingPathComponent(".codex/config.toml")
    try box.write(prefix, to: config)
    let integration = MCPIntegration(name: "film.craft", displayName: "FilmCraft", helper: box.integration.helper, arguments: ["a\"b", "\n", "世界"], env: ["A.B": "\\quoted\t"])
    let kit = MCPKit(integration, environment: .init(home: box.home, bundleURL: box.bundle))
    _ = try await kit.connect(.codex)
    #expect(await kit.status()[.codex] == .connected)
    let output = try String(contentsOf: config, encoding: .utf8)
    #expect(output.hasPrefix(prefix))
    #expect(output.contains("[mcp_servers.\"film.craft\"]"))
}

@Test(arguments: ["", "[mcp_servers.filmcraft]\ncommand = '/old'\n", "[mcp_servers.filmcraft.env]\nMODE = 'old'\n"])
func tomlRendersTheSameManagedFieldsForEveryLayout(original: String) throws {
    let base = try #require(AgentRegistry.load()[.codex])
    let definition = AgentDefinition(
        displayName: base.displayName, detect: base.detect, config: base.config,
        entry: .init(commandKey: "command", argsKey: "args", envKey: "env", typeKey: "type", type: "stdio"),
        skillsDir: base.skillsDir, restartHint: base.restartHint
    )
    let desired = ServerEntry(command: "/helper", args: ["mcp"], env: ["MODE": "test"], type: "stdio")
    let output = try TOMLDocument(Data(original.utf8)).updating(definition: definition, name: "filmcraft", entry: desired)
    #expect(try TOMLDocument(output).entry(definition: definition, name: "filmcraft") == desired)
}
