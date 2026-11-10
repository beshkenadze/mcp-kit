import Foundation

struct SkillInstaller {
    struct Marker: Codable, Equatable {
        let bundleID: String
        let version: String
    }

    let sources: [URL]
    let marker: Marker

    func validate(in directory: URL) throws {
        let fm = FileManager.default
        for source in sources {
            guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else { throw CocoaError(.fileReadNoSuchFile) }
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: destination.path) || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                _ = try ownedMarker(at: destination)
            }
        }
    }

    func isOutdated(in directory: URL) throws -> Bool {
        var outdated = false
        for source in sources {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            guard FileManager.default.fileExists(atPath: destination.path) else { outdated = true; continue }
            let existing = try ownedMarker(at: destination)
            if existing.version.compare(marker.version, options: .numeric) == .orderedAscending
                || !FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path) {
                outdated = true
            }
        }
        return outdated
    }

    func install(in directory: URL) throws {
        try validate(in: directory)
        let fm = FileManager.default
        var installed: Set<URL> = []
        for source in sources {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            guard installed.insert(destination).inserted else { continue }
            guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else { throw CocoaError(.fileReadNoSuchFile) }
            let exists = fm.fileExists(atPath: destination.path)
            if exists {
                let existing = try ownedMarker(at: destination)
                if existing == marker && fm.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path) { continue }
            } else if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil { throw MCPKitError.skillConflict(destination) }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".mcp-kit-\(UUID())")
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: source, to: temporary)
            try JSONEncoder().encode(marker).write(to: temporary.appendingPathComponent(".mcp-kit.json"))
            if exists { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
        }
    }

    func removeOwned(in directory: URL) throws {
        for source in sources {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if (try? ownedMarker(at: destination)) != nil { try FileManager.default.removeItem(at: destination) }
        }
    }

    private func ownedMarker(at destination: URL) throws -> Marker {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil,
              let data = try? Data(contentsOf: destination.appendingPathComponent(".mcp-kit.json")),
              let existing = try? JSONDecoder().decode(Marker.self, from: data), existing.bundleID == marker.bundleID else {
            throw MCPKitError.skillConflict(destination)
        }
        return existing
    }
}
