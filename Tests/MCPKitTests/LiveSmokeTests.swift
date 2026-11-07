import Foundation
import Testing
import MCPKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["MCPKIT_LIVE"] == "1"))
func liveSmokeRegistersAHelperAndChecksAgentCLIs() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let name = "mcpkit-smoke-\(UUID().uuidString.lowercased())"
    let integration = MCPIntegration(name: name, displayName: "MCPKit smoke", helper: .bundled("Contents/Helpers/filmcraft-cli"), arguments: ["mcp"])
    let environment = MCPEnvironment(home: FileManager.default.homeDirectoryForCurrentUser, bundleURL: box.bundle)
    let kit = MCPKit(integration, environment: environment)
    let statuses = await kit.status()
    try #require(statuses[.claudeCode] != .agentNotFound && statuses[.codex] != .agentNotFound)
    do {
        try await kit.connect(.claudeCode)
        try await kit.connect(.codex)
        for executable in ["claude", "codex"] {
            let output = try runAgentGet(executable, name: name)
            #expect(output.contains(name))
            #expect(output.contains("mcp-kit/bin/\(name)"))
        }
    } catch {
        try await kit.disconnectAll()
        throw error
    }
    try await kit.disconnectAll()
    #expect(await kit.status()[.claudeCode] == .disconnected)
    #expect(await kit.status()[.codex] == .disconnected)
}

private func runAgentGet(_ executable: String, name: String) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable, "mcp", "get", name]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
}
