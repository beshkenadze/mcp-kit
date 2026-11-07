import Foundation
import Testing
@testable import MCPKit

struct Sandbox {
    let root: URL
    let home: URL
    let bundle: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MCPKitTests-\(UUID())")
        home = root.appendingPathComponent("home")
        bundle = root.appendingPathComponent("FilmCraft.app")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try write("#!/bin/sh\n", to: bundle.appendingPathComponent("Contents/Helpers/filmcraft-cli"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent("Contents/Helpers/filmcraft-cli").path)
        let info: [String: String] = ["CFBundleIdentifier": "app.filmcraft", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func cleanup() throws { try FileManager.default.removeItem(at: root) }

    var integration: MCPIntegration {
        MCPIntegration(name: "filmcraft", displayName: "FilmCraft", helper: .bundled("Contents/Helpers/filmcraft-cli"), arguments: ["mcp"], env: ["MODE": "test"])
    }

    func kit(desktopInstalled: Bool = false) -> MCPKit {
        MCPKit(integration, environment: .init(home: home, bundleURL: bundle, applicationInstalled: { _ in desktopInstalled }))
    }
}

@Test func detectsOnlyRegisteredAgentsInInjectedHome() async throws {
    let box = try Sandbox()
    defer { try? box.cleanup() }
    #expect(await box.kit().status() == [.claudeCode: .agentNotFound, .claudeDesktop: .agentNotFound, .codex: .agentNotFound])
    try box.write("", to: box.home.appendingPathComponent(".claude.json"))
    try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
    #expect(await box.kit(desktopInstalled: true).status() == [.claudeCode: .disconnected, .claudeDesktop: .disconnected, .codex: .disconnected])
}

@Test func registryShipsTheApprovedPathsAndTemplates() throws {
    let agents = try AgentRegistry.load()
    #expect(agents[.claudeCode]?.config.path == "~/.claude.json")
    #expect(agents[.claudeCode]?.entry.type == "stdio")
    #expect(agents[.claudeDesktop]?.entry.type == nil)
    #expect(agents[.claudeDesktop]?.detect.bundleID == "com.anthropic.claudefordesktop")
    #expect(agents[.codex]?.skillsDir == "~/.agents/skills")
    #expect(agents[.codex]?.entry.argsKey == "args")
}
