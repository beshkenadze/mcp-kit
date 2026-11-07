import Foundation

struct AgentDefinition: Decodable, Sendable {
    struct Detection: Decodable, Sendable {
        let paths: [String]
        let bundleID: String?
    }

    struct Config: Decodable, Sendable {
        let path: String
        let format: String
        let serversKey: String
    }

    struct Entry: Decodable, Sendable {
        let commandKey: String
        let argsKey: String
        let envKey: String
        let typeKey: String?
        let type: String?
    }

    let displayName: String
    let detect: Detection
    let config: Config
    let entry: Entry
    let skillsDir: String?
    let restartHint: String?

    func isDetected(in environment: MCPEnvironment) -> Bool {
        detect.paths.contains { FileManager.default.fileExists(atPath: environment.expand($0).path) }
            || detect.bundleID.map(environment.applicationInstalled) == true
    }
}

enum AgentRegistry {
    static func load() throws -> [AgentID: AgentDefinition] {
        let url = Bundle.module.url(forResource: "agents", withExtension: "json")!
        let decoded = try JSONDecoder().decode([String: AgentDefinition].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: try decoded.map { key, value in
            guard let id = AgentID(rawValue: key) else { throw CocoaError(.fileReadCorruptFile) }
            return (id, value)
        })
    }
}
