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
                    guard entry == (try desiredEntry()) else { return .outdated }
                    if let directory = skillDirectory(definition), try skillInstaller().isOutdated(in: directory) { return .outdated }
                    return .connected
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
                catch TOMLError.unsupportedLayout { throw MCPKitError.unsupportedLayout(agent, url) }
                catch { throw MCPKitError.unreadableConfig(agent, url, underlying: error) }
            }, verify: { data in
                try ConfigReader.entry(in: data, definition: definition, name: name) == desired
            })
            if let directory = skillDirectory(definition) { try skillInstaller().install(in: directory) }
            logger.info("Connected \(agent.rawValue, privacy: .public)")
            return ConnectResult(restartHint: definition.restartHint)
        } catch let error as MCPKitError { throw error }
        catch WriteVerificationError.failed { throw MCPKitError.verificationFailed(agent) }
        catch { throw MCPKitError.writeFailed(agent, url, underlying: error) }
    }

    public func disconnect(_ agent: AgentID) throws {
        let registry = try AgentRegistry.load()
        let definition = registry[agent]!
        let url = environment.expand(definition.config.path)
        do {
            let command = try helperLink().path
            let name = integration.name
            if try readEntry(agent, definition: definition)?.command == command {
                try writer.update(url, transform: { data in
                    do {
                        guard try ConfigReader.entry(in: data, definition: definition, name: name)?.command == command else { return data ?? Data() }
                        return try ConfigReader.updating(data, definition: definition, name: name, entry: nil)
                    } catch TOMLError.unsupportedLayout { throw MCPKitError.unsupportedLayout(agent, url) }
                    catch { throw MCPKitError.unreadableConfig(agent, url, underlying: error) }
                }, verify: { data in
                    try ConfigReader.entry(in: data, definition: definition, name: name)?.command != command
                })
            }
            var remaining: [AgentDefinition] = []
            for id in AgentID.allCases where id != agent {
                let other = registry[id]!
                if try readEntry(id, definition: other)?.command == command { remaining.append(other) }
            }
            if let directory = skillDirectory(definition), !remaining.contains(where: { skillDirectory($0) == directory }) {
                try skillInstaller().removeOwned(in: directory)
            }
            if remaining.isEmpty, (try? FileManager.default.destinationOfSymbolicLink(atPath: command)) != nil {
                try FileManager.default.removeItem(atPath: command)
            }
            logger.info("Disconnected \(agent.rawValue, privacy: .public)")
        } catch let error as MCPKitError { throw error }
        catch WriteVerificationError.failed { throw MCPKitError.verificationFailed(agent) }
        catch { throw MCPKitError.writeFailed(agent, url, underlying: error) }
    }

    public func disconnectAll() throws {
        var firstError: (any Error)?
        for agent in AgentID.allCases {
            do { try disconnect(agent) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    public func reconcile() throws {
        try updateHelperLink()
        let statuses = status()
        for agent in AgentID.allCases where statuses[agent] == .outdated { try connect(agent) }
    }

    private func readEntry(_ agent: AgentID, definition: AgentDefinition) throws -> ServerEntry? {
        let url = environment.expand(definition.config.path)
        do { return try ConfigReader.entry(in: ConfigReader.data(at: url), definition: definition, name: integration.name) }
        catch TOMLError.unsupportedLayout { throw MCPKitError.unsupportedLayout(agent, url) }
        catch { throw MCPKitError.unreadableConfig(agent, url, underlying: error) }
    }

    private func skillDirectory(_ definition: AgentDefinition) -> URL? {
        definition.skillsDir.map { environment.expand($0).resolvingSymlinksInPath() }
    }

    private func skillInstaller() throws -> SkillInstaller {
        let info = try bundleInfo()
        guard let bundleID = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        return SkillInstaller(sources: integration.skills.map { $0.resolve(in: environment.bundleURL) }, marker: .init(bundleID: bundleID, version: version))
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
