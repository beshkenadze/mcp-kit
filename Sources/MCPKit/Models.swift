import AppKit
import Foundation

public enum AgentID: String, CaseIterable, Codable, Sendable {
    case claudeCode, claudeDesktop, codex
}

public enum AgentStatus: Equatable, Sendable {
    case agentNotFound, disconnected, connected, outdated, conflict
    case unavailable(String)
}

public enum BundledResource: Sendable {
    case bundled(String)

    func resolve(in bundleURL: URL) -> URL {
        switch self {
        case .bundled(let path): bundleURL.appendingPathComponent(path)
        }
    }
}

public struct MCPIntegration: Sendable {
    public let name: String
    public let displayName: String
    public let helper: BundledResource
    public let arguments: [String]
    public let env: [String: String]
    public let skills: [BundledResource]

    public init(name: String, displayName: String, helper: BundledResource, arguments: [String] = [], env: [String: String] = [:], skills: [BundledResource] = []) {
        self.name = name
        self.displayName = displayName
        self.helper = helper
        self.arguments = arguments
        self.env = env
        self.skills = skills
    }
}

public struct ConnectResult: Equatable, Sendable {
    public let restartHint: String?
}

public enum MCPKitError: Error {
    case helperMissing(URL)
    case conflict(AgentID, existingCommand: String)
    case unreadableConfig(AgentID, URL, underlying: any Error)
    case unsupportedLayout(AgentID, URL)
    case skillConflict(URL)
    case writeFailed(AgentID, URL, underlying: any Error)
    case verificationFailed(AgentID)
}

public struct MCPEnvironment: Sendable {
    public let home: URL
    public let bundleURL: URL
    let applicationInstalled: @Sendable (String) -> Bool

    public init(home: URL, bundleURL: URL, applicationInstalled: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.home = home
        self.bundleURL = bundleURL
        self.applicationInstalled = applicationInstalled
    }

    public static var live: MCPEnvironment {
        .init(home: FileManager.default.homeDirectoryForCurrentUser, bundleURL: Bundle.main.bundleURL, applicationInstalled: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        })
    }

    func expand(_ path: String) -> URL {
        path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : URL(fileURLWithPath: path)
    }
}
