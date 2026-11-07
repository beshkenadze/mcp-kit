import Darwin
import Foundation

public protocol ConfigWriter: Sendable {
    func update(_ url: URL, transform: @Sendable (Data?) throws -> Data, verify: @Sendable (Data?) throws -> Bool) throws
}

enum WriteVerificationError: Error { case failed }
struct ConfigReadError: Error { let underlying: any Error }

public struct FileWriter: ConfigWriter {
    private let afterWrite: (@Sendable (URL, Int) throws -> Void)?

    public init() { afterWrite = nil }

    init(afterWrite: @escaping @Sendable (URL, Int) throws -> Void) { self.afterWrite = afterWrite }

    public func update(_ url: URL, transform: @Sendable (Data?) throws -> Data, verify: @Sendable (Data?) throws -> Bool) throws {
        let fm = FileManager.default
        for attempt in 0..<2 {
            let original: Data?
            do { original = try ConfigReader.data(at: url) }
            catch { throw ConfigReadError(underlying: error) }
            let output = try transform(original)
            if output == original, (try? verify(original)) == true { return }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let permissions = original == nil ? 0o600 : (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? 0o600)
            if let original {
                let backup = URL(fileURLWithPath: url.path + ".mcp-kit.bak")
                try atomicWrite(original, to: backup, permissions: permissions)
            }
            try atomicWrite(output, to: url, permissions: permissions)
            try afterWrite?(url, attempt)
            if (try? verify(ConfigReader.data(at: url))) == true { return }
        }
        throw WriteVerificationError.failed
    }

    private func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".mcp-kit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
