import Foundation
import Testing
@testable import MCPKit

final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Test(arguments: [AgentID.claudeCode, .codex])
func retriesOnceUsingTheLatestConfigAfterAnExternalOverwrite(agent: AgentID) async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let definition = try #require(AgentRegistry.load()[agent])
    let config = MCPEnvironment(home: box.home, bundleURL: box.bundle).expand(definition.config.path)
    try box.write(agent == .codex ? "# initial\n" : "{}", to: config)
    let counter = AttemptCounter()
    let replacement = agent == .codex ? "# external\nmodel = 'latest'\n" : "{\"model\":\"latest\",\"mcpServers\":{\"other\":{\"command\":\"/other\"}}}"
    let writer = FileWriter(afterWrite: { url, attempt in
        counter.increment()
        if attempt == 0 { try Data(replacement.utf8).write(to: url) }
    })
    let kit = MCPKit(box.integration, environment: .init(home: box.home, bundleURL: box.bundle), writer: writer)
    _ = try await kit.connect(agent)
    #expect(counter.value == 2)
    #expect(await kit.status()[agent] == .connected)
    let output = try String(contentsOf: config, encoding: .utf8)
    #expect(output.contains("latest"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: config.path + ".mcp-kit.bak")) == Data(replacement.utf8))
}

@Test func reportsVerificationFailureAfterExactlyTwoAttempts() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.write("{}", to: box.home.appendingPathComponent(".claude.json"))
    let counter = AttemptCounter()
    let writer = FileWriter(afterWrite: { url, _ in counter.increment(); try Data("{}".utf8).write(to: url) })
    let kit = MCPKit(box.integration, environment: .init(home: box.home, bundleURL: box.bundle), writer: writer)
    do { try await kit.connect(.claudeCode); Issue.record("Expected verification failure") }
    catch MCPKitError.verificationFailed(let agent) { #expect(agent == .claudeCode) }
    #expect(counter.value == 2)
}

@Test func retryRefusesAnExternallyIntroducedConflict() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    try box.write("{}", to: box.home.appendingPathComponent(".claude.json"))
    let writer = FileWriter(afterWrite: { url, _ in
        try Data("{\"mcpServers\":{\"filmcraft\":{\"command\":\"/other\"}}}".utf8).write(to: url)
    })
    let kit = MCPKit(box.integration, environment: .init(home: box.home, bundleURL: box.bundle), writer: writer)
    do { try await kit.connect(.claudeCode); Issue.record("Expected conflict") }
    catch MCPKitError.conflict(let agent, let command) { #expect(agent == .claudeCode); #expect(command == "/other") }
    #expect(await kit.status()[.claudeCode] == .conflict)
}

@Test func unreadableFilesHaveTheDocumentedError() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = box.home.appendingPathComponent(".claude.json")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    do { try await box.kit().connect(.claudeCode); Issue.record("Expected unreadable config") }
    catch MCPKitError.unreadableConfig(let agent, let url, _) { #expect(agent == .claudeCode); #expect(url.path == config.path) }
}

@Test func preservesExistingPermissionsAndLeavesNoTemporaryFiles() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let config = box.home.appendingPathComponent(".claude.json")
    try box.write("{\"theme\":\"light\"}", to: config)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)
    _ = try await box.kit().connect(.claudeCode)
    #expect(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int == 0o640)
    #expect(try FileManager.default.attributesOfItem(atPath: config.path + ".mcp-kit.bak")[.posixPermissions] as? Int == 0o640)
    #expect(try FileManager.default.contentsOfDirectory(atPath: box.home.path).allSatisfy { !$0.hasPrefix(".mcp-kit-") })
}
