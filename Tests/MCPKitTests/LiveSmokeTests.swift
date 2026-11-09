import Foundation
import Testing
import MCPKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["MCPKIT_LIVE"] == "1"))
func liveSmokeRegistersAHelperAndChecksAgentCLIs() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    let name = "mcpkit-smoke-\(UUID().uuidString.lowercased())"
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let builtHelper = package.appendingPathComponent(".build/debug/ExampleHelper")
    try #require(FileManager.default.isExecutableFile(atPath: builtHelper.path), "Run swift build first")
    let helper = box.bundle.appendingPathComponent("Contents/Helpers/filmcraft-cli")
    try FileManager.default.removeItem(at: helper)
    try FileManager.default.copyItem(at: builtHelper, to: helper)
    let bundleID = "app.mcpkit.smoke.\(UUID().uuidString.lowercased())"
    let info = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "1.0"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: box.bundle.appendingPathComponent("Contents/Info.plist"))
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(bundleID)")
    defer { try? FileManager.default.removeItem(at: support) }
    let integration = MCPIntegration(name: name, displayName: "MCPKit smoke", helper: .bundled("Contents/Helpers/filmcraft-cli"))
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
            if executable == "claude" {
                #expect(output.range(of: #"(?im)^\s*Status:\s*(?:[✓✔]\s*)?Connected\s*$"#, options: .regularExpression) != nil)
            }
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
    process.standardError = output
    var environment = ProcessInfo.processInfo.environment
    environment["NO_COLOR"] = "1"
    process.environment = environment
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
}
