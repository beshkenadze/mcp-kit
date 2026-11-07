import Foundation
import os

public actor MCPKit {
    let integration: MCPIntegration
    let environment: MCPEnvironment
    let writer: any ConfigWriter
    let logger = Logger(subsystem: "mcp-kit", category: "integration")

    public init(_ integration: MCPIntegration, environment: MCPEnvironment = .live, writer: any ConfigWriter = FileWriter()) {
        self.integration = integration
        self.environment = environment
        self.writer = writer
    }

    public func status() -> [AgentID: AgentStatus] {
        do {
            return try AgentRegistry.load().mapValues { definition in
                guard definition.isDetected(in: environment) else { return .agentNotFound }
                do {
                    let url = environment.expand(definition.config.path)
                    guard let entry = try ConfigReader.entry(in: ConfigReader.data(at: url), definition: definition, name: integration.name) else { return .disconnected }
                    guard entry.command == (try helperLink().path) else { return .conflict }
                    return entry == (try desiredEntry()) ? .connected : .outdated
                } catch { return .unavailable(error.localizedDescription) }
            }
        } catch {
            return Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, .unavailable(error.localizedDescription)) })
        }
    }

    @discardableResult
    public func connect(_ agent: AgentID, force: Bool = false) throws -> ConnectResult {
        let definition = try AgentRegistry.load()[agent]!
        guard definition.isDetected(in: environment) else { return ConnectResult(restartHint: nil) }
        let url = environment.expand(definition.config.path)
        do {
            try updateHelperLink()
            let desired = try desiredEntry()
            let name = integration.name
            try writer.update(url, transform: { data in
                do {
                    let existing = try ConfigReader.entry(in: data, definition: definition, name: name)
                    if let existing, existing.command != desired.command, !force {
                        throw MCPKitError.conflict(agent, existingCommand: existing.command)
                    }
                    return try ConfigReader.updating(data, definition: definition, name: name, entry: desired)
                } catch let error as MCPKitError { throw error }
                catch { throw MCPKitError.unreadableConfig(agent, url, underlying: error) }
            }, verify: { data in
                try ConfigReader.entry(in: data, definition: definition, name: name) == desired
            })
            logger.info("Connected \(agent.rawValue, privacy: .public)")
            return ConnectResult(restartHint: definition.restartHint)
        } catch let error as MCPKitError { throw error }
        catch WriteVerificationError.failed { throw MCPKitError.verificationFailed(agent) }
        catch { throw MCPKitError.writeFailed(agent, url, underlying: error) }
    }

    func bundleInfo() throws -> [String: Any] {
        let data = try Data(contentsOf: environment.bundleURL.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return info
    }

    func helperLink() throws -> URL {
        guard let bundleID = try bundleInfo()["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty, !bundleID.contains("/"),
              !integration.name.isEmpty, ![".", ".."].contains(integration.name), !integration.name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return environment.home.appendingPathComponent("Library/Application Support/\(bundleID)/mcp-kit/bin/\(integration.name)")
    }

    func desiredEntry() throws -> ServerEntry {
        ServerEntry(command: try helperLink().path, args: integration.arguments, env: integration.env)
    }

    func updateHelperLink() throws {
        let helper = integration.helper.resolve(in: environment.bundleURL)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw MCPKitError.helperMissing(helper) }
        let link = try helperLink()
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == helper.path { return }
        if fm.fileExists(atPath: link.path), (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".mcp-kit-\(UUID())")
        defer { try? fm.removeItem(at: temporary) }
        try fm.createSymbolicLink(at: temporary, withDestinationURL: helper)
        guard rename(temporary.path, link.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
