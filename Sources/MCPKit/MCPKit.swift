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
            return status(registry: try AgentRegistry.load(), resources: Result { try resolveResources() })
        } catch {
            return Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, .unavailable(error.localizedDescription)) })
        }
    }

    private func status(registry: [AgentID: AgentDefinition], resources: Result<Resources, any Error>) -> [AgentID: AgentStatus] {
        registry.mapValues { definition in
            guard definition.isDetected(in: environment) else { return .agentNotFound }
            do {
                let url = environment.expand(definition.config.path)
                guard let entry = try ConfigReader.entry(in: ConfigReader.data(at: url), definition: definition, name: integration.name) else { return .disconnected }
                let resources = try resources.get()
                guard resources.commands.contains(entry.command) else { return .conflict }
                guard entry == desiredEntry(resources, definition: definition) else { return .outdated }
                if let directory = skillDirectory(definition), try skillInstaller(resources).isOutdated(in: directory) { return .outdated }
                return .connected
            } catch { return .unavailable(error.localizedDescription) }
        }
    }

    @discardableResult
    public func connect(_ agent: AgentID, force: Bool = false) throws -> ConnectResult {
        let definition = try AgentRegistry.load()[agent]!
        return try connect(agent, definition: definition, resources: Result { try resolveResources() }, force: force)
    }

    private func connect(_ agent: AgentID, definition: AgentDefinition, resources: Result<Resources, any Error>, force: Bool = false) throws -> ConnectResult {
        guard definition.isDetected(in: environment) else { throw MCPKitError.agentNotFound(agent) }
        let url = environment.expand(definition.config.path)
        do {
            let resources = try resources.get()
            let desired = desiredEntry(resources, definition: definition)
            let commands = resources.commands
            let directory = skillDirectory(definition)
            let installer = try directory.map { _ in try skillInstaller(resources) }
            let name = integration.name
            let transform: @Sendable (Data?) throws -> Data = { data in
                do {
                    let existing = try ConfigReader.entry(in: data, definition: definition, name: name)
                    if let existing, !commands.contains(existing.command), !force {
                        throw MCPKitError.conflict(agent, existingCommand: existing.command)
                    }
                    if existing == desired, let data { return data }
                    let base: Data?
                    if let existing, !commands.contains(existing.command) {
                        base = try ConfigReader.updating(data, definition: definition, name: name, entry: nil)
                    } else { base = data }
                    return try ConfigReader.updating(base, definition: definition, name: name, entry: desired)
                } catch let error as MCPKitError { throw error }
                catch TOMLError.unsupportedLayout { throw MCPKitError.unsupportedLayout(agent, url) }
                catch { throw MCPKitError.unreadableConfig(agent, url, underlying: error) }
            }
            let original: Data?
            do { original = try ConfigReader.data(at: url) }
            catch { throw ConfigReadError(underlying: error) }
            _ = try transform(original)
            if let directory, let installer { try installer.validate(in: directory) }
            try updateHelperLink(resources)
            try writer.update(url, transform: transform, verify: { data in
                try ConfigReader.entry(in: data, definition: definition, name: name) == desired
            })
            if let directory, let installer { try installer.install(in: directory) }
            logger.info("Connected \(agent.rawValue, privacy: .public)")
            return ConnectResult(restartHint: definition.restartHint)
        } catch let error as MCPKitError { throw error }
        catch let error as ConfigReadError { throw MCPKitError.unreadableConfig(agent, url, underlying: error.underlying) }
        catch WriteVerificationError.failed { throw MCPKitError.verificationFailed(agent) }
        catch { throw MCPKitError.writeFailed(agent, url, underlying: error) }
    }

    public func disconnect(_ agent: AgentID) throws {
        let registry = try AgentRegistry.load()
        try disconnect(agent, registry: registry, resources: Result { try resolveResources() })
    }

    private func disconnect(_ agent: AgentID, registry: [AgentID: AgentDefinition], resources: Result<Resources, any Error>) throws {
        let definition = registry[agent]!
        let url = environment.expand(definition.config.path)
        do {
            let resources = try resources.get()
            let command = resources.link.path
            let commands = resources.commands
            let name = integration.name
            if let entry = try readEntry(agent, definition: definition), commands.contains(entry.command) {
                try writer.update(url, transform: { data in
                    do {
                        guard let entry = try ConfigReader.entry(in: data, definition: definition, name: name),
                              commands.contains(entry.command) else { return data ?? Data() }
                        return try ConfigReader.updating(data, definition: definition, name: name, entry: nil)
                    } catch TOMLError.unsupportedLayout { throw MCPKitError.unsupportedLayout(agent, url) }
                    catch { throw MCPKitError.unreadableConfig(agent, url, underlying: error) }
                }, verify: { data in
                    guard let entry = try ConfigReader.entry(in: data, definition: definition, name: name) else { return true }
                    return !commands.contains(entry.command)
                })
            }
            var remaining: [AgentDefinition] = []
            for id in AgentID.allCases where id != agent {
                let other = registry[id]!
                do {
                    if let entry = try readEntry(id, definition: other), commands.contains(entry.command) { remaining.append(other) }
                } catch {
                    remaining.append(other)
                    logger.warning("Keeping resources for unreadable \(id.rawValue, privacy: .public) configuration")
                }
            }
            if let directory = skillDirectory(definition), !remaining.contains(where: { skillDirectory($0) == directory }) {
                try skillInstaller(resources).removeOwned(in: directory)
            }
            if remaining.isEmpty, (try? FileManager.default.destinationOfSymbolicLink(atPath: command)) != nil {
                try FileManager.default.removeItem(atPath: command)
            }
            logger.info("Disconnected \(agent.rawValue, privacy: .public)")
        } catch let error as MCPKitError { throw error }
        catch let error as ConfigReadError { throw MCPKitError.unreadableConfig(agent, url, underlying: error.underlying) }
        catch WriteVerificationError.failed { throw MCPKitError.verificationFailed(agent) }
        catch { throw MCPKitError.writeFailed(agent, url, underlying: error) }
    }

    public func disconnectAll() throws {
        let registry = try AgentRegistry.load()
        let resources = Result { try resolveResources() }
        var firstError: (any Error)?
        for agent in AgentID.allCases {
            do { try disconnect(agent, registry: registry, resources: resources) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    public func reconcile() throws {
        let registry = try AgentRegistry.load()
        let resources = try resolveResources()
        let link = resources.link
        let linkExists = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
        let commands = resources.commands
        let hasOwnedEntry = registry.contains { agent, definition in
            guard let entry = try? readEntry(agent, definition: definition) else { return false }
            return commands.contains(entry.command)
        }
        guard linkExists || hasOwnedEntry else { return }
        try updateHelperLink(resources)
        let statuses = status(registry: registry, resources: .success(resources))
        var firstError: (any Error)?
        for agent in AgentID.allCases where statuses[agent] == .outdated {
            do { _ = try connect(agent, definition: registry[agent]!, resources: .success(resources)) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
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

    private func skillInstaller(_ resources: Resources) throws -> SkillInstaller {
        guard let version = resources.version else { throw CocoaError(.fileReadCorruptFile) }
        return SkillInstaller(sources: integration.skills.map { $0.resolve(in: environment.bundleURL) }, marker: .init(bundleID: resources.bundleID, version: version))
    }

    private struct Resources {
        let bundleID: String
        let version: String?
        let helper: URL
        let link: URL
        let commands: [String]
    }

    private func resolveResources() throws -> Resources {
        let data = try Data(contentsOf: environment.bundleURL.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        guard let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty, !bundleID.contains("/"),
              !integration.name.isEmpty, ![".", ".."].contains(integration.name), !integration.name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let link = environment.home.appendingPathComponent("Library/Application Support/\(bundleID)/mcp-kit/bin/\(integration.name)")
        return Resources(bundleID: bundleID, version: info["CFBundleShortVersionString"] as? String,
                         helper: integration.helper.resolve(in: environment.bundleURL), link: link,
                         commands: [link.path] + integration.legacyCommands.filter { !$0.isEmpty })
    }

    private func desiredEntry(_ resources: Resources, definition: AgentDefinition) -> ServerEntry {
        ServerEntry(command: resources.link.path, args: integration.arguments, env: integration.env, type: definition.entry.type)
    }

    private func updateHelperLink(_ resources: Resources) throws {
        let helper = resources.helper
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw MCPKitError.helperMissing(helper) }
        let link = resources.link
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
