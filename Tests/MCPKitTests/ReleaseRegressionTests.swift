import Foundation
import Testing
@testable import MCPKit

private func helperLink(_ box: Sandbox) -> URL {
    box.home.appendingPathComponent("Library/Application Support/app.filmcraft/mcp-kit/bin/filmcraft")
}

private func configuration(_ box: Sandbox, agent: AgentID) throws -> URL {
    let definition = try #require(AgentRegistry.load()[agent])
    return MCPEnvironment(home: box.home, bundleURL: box.bundle).expand(definition.config.path)
}

@Test(arguments: AgentID.allCases)
func conflictLeavesNoHelperLink(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    let original = agent == .codex ? "[mcp_servers.filmcraft]\ncommand = '/foreign'\n" : #"{"mcpServers":{"filmcraft":{"command":"/foreign"}}}"#
    try box.write(original, to: config)
    do { try await box.kit(desktopInstalled: true).connect(agent); Issue.record("Expected conflict") }
    catch MCPKitError.conflict(let owner, _) { #expect(owner == agent) }
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: helperLink(box).path)) == nil)
    #expect(try Data(contentsOf: config) == Data(original.utf8))
}

@Test(arguments: [AgentID.claudeCode, .codex])
func skillConflictLeavesNoRegisteredEntry(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    let definition = try #require(AgentRegistry.load()[agent])
    let directory = try #require(definition.skillsDir)
    try FileManager.default.createDirectory(at: try configuration(box, agent: agent).deletingLastPathComponent(), withIntermediateDirectories: true)
    let environment = MCPEnvironment(home: box.home, bundleURL: box.bundle)
    let skill = environment.expand(directory).appendingPathComponent("filmcraft/SKILL.md")
    try box.write("foreign", to: skill)
    let kit = MCPKit(box.skilledIntegration, environment: environment)
    do { try await kit.connect(agent); Issue.record("Expected skill conflict") }
    catch MCPKitError.skillConflict { }
    #expect(!FileManager.default.fileExists(atPath: try configuration(box, agent: agent).path))
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: helperLink(box).path)) == nil)
    #expect(try String(contentsOf: skill, encoding: .utf8) == "foreign")
}

@Test(arguments: [AgentID.claudeCode, .codex], ["unreadable", "missing helper", "missing skill", "later missing skill", "later skill conflict"])
func preflightFailuresLeaveNoNewResources(agent: AgentID, failure: String) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.prepareSkills()
    let config = try configuration(box, agent: agent)
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    let definition = try #require(AgentRegistry.load()[agent])
    let environment = MCPEnvironment(home: box.home, bundleURL: box.bundle)
    let skills = environment.expand(try #require(definition.skillsDir))
    var resources = box.skilledIntegration.skills
    switch failure {
    case "unreadable": try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    case "missing helper": try FileManager.default.removeItem(at: box.bundle.appendingPathComponent("Contents/Helpers/filmcraft-cli"))
    case "missing skill": try FileManager.default.removeItem(at: box.bundle.appendingPathComponent("Skills/filmcraft/SKILL.md"))
    case "later missing skill": resources.append(.bundled("Skills/missing"))
    default:
        resources.append(.bundled("Skills/foreign"))
        try box.write("source", to: box.bundle.appendingPathComponent("Skills/foreign/SKILL.md"))
        try box.write("foreign", to: skills.appendingPathComponent("foreign/SKILL.md"))
    }
    let base = box.integration
    let integration = MCPIntegration(name: base.name, displayName: base.displayName, helper: base.helper, skills: resources)
    let kit = MCPKit(integration, environment: environment)
    await #expect(throws: (any Error).self) { try await kit.connect(agent) }
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: helperLink(box).path)) == nil)
    #expect(!FileManager.default.fileExists(atPath: skills.appendingPathComponent("filmcraft").path))
    if failure == "unreadable" {
        #expect(try FileManager.default.contentsOfDirectory(atPath: config.path).isEmpty)
    } else { #expect(!FileManager.default.fileExists(atPath: config.path)) }
}

@Test func unsupportedLayoutLeavesNoHelperLink() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: .codex)
    let original = "mcp_servers.filmcraft.command = '/foreign'\n"
    try box.write(original, to: config)
    do { try await box.kit().connect(.codex, force: true); Issue.record("Expected unsupported layout") }
    catch MCPKitError.unsupportedLayout { }
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: helperLink(box).path)) == nil)
    #expect(try Data(contentsOf: config) == Data(original.utf8))
}

@Test(arguments: AgentID.allCases)
func forceReplacesForeignEntryCompletely(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    let original = agent == .codex ? """
    model = 'keep'
    [mcp_servers.other]
    command = '/other'
    [mcp_servers.filmcraft]
    type = 'http'
    url = 'https://x'
    disabled = true
    [mcp_servers.filmcraft.headers]
    A = 'b'
    [mcp_servers.filmcraft.tools.search]
    approval_mode = 'prompt'

    """ : #"{"model":"keep","mcpServers":{"other":{"command":"/other"},"filmcraft":{"type":"http","url":"https://x","headers":{"A":"b"},"disabled":true}}}"#
    try box.write(original, to: config)
    let kit = box.kit(desktopInstalled: true)
    try await kit.connect(agent, force: true)
    #expect(await kit.status()[agent] == .connected)
    let data = try Data(contentsOf: config)
    if agent == .codex {
        let text = String(decoding: data, as: UTF8.self)
        for field in ["type =", "url =", "disabled =", ".headers]", ".tools.search]"] { #expect(!text.contains(field)) }
        #expect(text.contains("model = 'keep'"))
        #expect(text.contains("command = '/other'"))
    } else {
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: [String: Any]])
        let entry = try #require(servers["filmcraft"])
        #expect(Set(entry.keys) == Set(agent == .claudeCode ? ["type", "command", "args", "env"] : ["command", "args", "env"]))
        #expect(root["model"] as? String == "keep")
        #expect(servers["other"]?["command"] as? String == "/other")
    }
}

@Test(arguments: AgentID.allCases, [false, true])
func connectOnCorrectEntryDoesNotRewriteFile(agent: AgentID, existingBackup: Bool) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: agent)
    try box.write(agent == .codex ? "# initial\n" : "{}", to: config)
    let kit = box.kit(desktopInstalled: true)
    try await kit.connect(agent)
    let type = agent == .claudeCode ? #""type":"stdio","# : ""
    let text = agent == .codex ? """
    # preserve formatting
    ratio = 0.1
    precise = 1.0
    [mcp_servers.filmcraft]
    command = '\(helperLink(box).path)'
    args = ['mcp'] # keep
    [mcp_servers.filmcraft.env]
    MODE = 'test'

    """ : """
    {"ratio":0.1,"precise":1.0,"zeta":1,"mcpServers":{"filmcraft":{\(type)"command":"\(helperLink(box).path)","args":["mcp"],"env":{"MODE":"test"}}}}
    """
    try box.write(text, to: config)
    let backup = URL(fileURLWithPath: config.path + ".mcp-kit.bak")
    if existingBackup { try box.write("original backup", to: backup) }
    else { try FileManager.default.removeItem(at: backup) }
    try await kit.connect(agent)
    #expect(try Data(contentsOf: config) == Data(text.utf8))
    if existingBackup { #expect(try String(contentsOf: backup, encoding: .utf8) == "original backup") }
    else { #expect(!FileManager.default.fileExists(atPath: backup.path)) }
}

@Test func reconnectRepairsTheManagedTransportType() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = try configuration(box, agent: .claudeCode)
    try box.write("""
    {"mcpServers":{"filmcraft":{"type":"http","command":"\(helperLink(box).path)","args":["mcp"],"env":{"MODE":"test"}}}}
    """, to: config)
    try await box.kit().connect(.claudeCode)
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
    let entry = try #require((root["mcpServers"] as? [String: [String: Any]])?["filmcraft"])
    #expect(entry["type"] as? String == "stdio")
}
