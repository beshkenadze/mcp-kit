import CryptoKit
import Foundation

struct SkillInstaller {
    struct Marker: Codable, Equatable {
        let bundleID: String
        let version: String
        var digest: String? = nil
    }

    let sources: [URL]
    let marker: Marker

    func validate(in directory: URL) throws {
        let fm = FileManager.default
        for source in sources {
            guard fm.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else { throw CocoaError(.fileReadNoSuchFile) }
            _ = try contentDigest(at: source)
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
            if try isOutdated(source: source, destination: destination, existing: existing) { outdated = true }
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
                if try !isOutdated(source: source, destination: destination, existing: existing) { continue }
            } else if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil { throw MCPKitError.skillConflict(destination) }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".mcp-kit-\(UUID())")
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: source, to: temporary)
            var installedMarker = marker
            installedMarker.digest = try contentDigest(at: source)
            try JSONEncoder().encode(installedMarker).write(to: temporary.appendingPathComponent(".mcp-kit.json"))
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

    private func isOutdated(source: URL, destination: URL, existing: Marker) throws -> Bool {
        guard existing.version.compare(marker.version, options: .numeric) != .orderedAscending,
              let digest = existing.digest,
              FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path) else { return true }
        return try digest != contentDigest(at: source) || digest != contentDigest(at: destination)
    }

    private func contentDigest(at directory: URL) throws -> String {
        let fm = FileManager.default
        var hash = SHA256()
        func append(_ data: Data) {
            hash.update(data: Data("\(data.count):".utf8))
            hash.update(data: data)
        }
        for path in try fm.subpathsOfDirectory(atPath: directory.path).sorted() where path != ".mcp-kit.json" {
            let url = directory.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            append(Data(path.utf8))
            if values.isSymbolicLink == true {
                append(Data("symlink".utf8))
                append(Data(try fm.destinationOfSymbolicLink(atPath: url.path).utf8))
            } else if values.isDirectory == true { append(Data("directory".utf8)) }
            else {
                append(Data("file".utf8))
                append(try Data(contentsOf: url))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
