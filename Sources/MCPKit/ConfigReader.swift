import Foundation

struct ServerEntry: Equatable, Sendable {
    let command: String
    let args: [String]
    let env: [String: String]
}

enum ConfigReader {
    static func data(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    static func entry(in data: Data?, definition: AgentDefinition, name: String) throws -> ServerEntry? {
        if definition.config.format == "toml" { return try TOMLDocument(data).entry(definition: definition, name: name) }
        let root = try json(data)
        guard let value = try servers(root, key: definition.config.serversKey)[name] else { return nil }
        guard let object = value as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let keys = definition.entry
        let command = object[keys.commandKey] as? String ?? ""
        guard object[keys.argsKey] == nil || object[keys.argsKey] is [String],
              object[keys.envKey] == nil || object[keys.envKey] is [String: String] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return ServerEntry(command: command, args: object[keys.argsKey] as? [String] ?? [], env: object[keys.envKey] as? [String: String] ?? [:])
    }

    static func updating(_ data: Data?, definition: AgentDefinition, name: String, entry: ServerEntry?) throws -> Data {
        if definition.config.format == "toml" { return try TOMLDocument(data).updating(definition: definition, name: name, entry: entry) }
        var root = try json(data)
        var servers = try servers(root, key: definition.config.serversKey)
        if let entry {
            let keys = definition.entry
            var object: [String: Any] = [keys.commandKey: entry.command, keys.argsKey: entry.args, keys.envKey: entry.env]
            if let key = keys.typeKey, let type = keys.type { object[key] = type }
            servers[name] = object
        } else { servers.removeValue(forKey: name) }
        root[definition.config.serversKey] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    private static func json(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return root
    }

    private static func servers(_ root: [String: Any], key: String) throws -> [String: Any] {
        guard let value = root[key] else { return [:] }
        guard let servers = value as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return servers
    }
}
