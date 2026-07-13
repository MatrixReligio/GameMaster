import Foundation
import GMModel

/// Owns the `runtimes/` directory under the app-support root. All paths flow
/// through here so tests can point the whole engine at a temp directory.
public actor RuntimeStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var runtimesDirectory: URL {
        root.appendingPathComponent("runtimes", isDirectory: true)
    }

    public func runtimeDirectory(id: String) -> URL {
        runtimesDirectory.appendingPathComponent(id, isDirectory: true)
    }

    public func wineBinary(for descriptor: RuntimeDescriptor) -> URL {
        runtimeDirectory(id: descriptor.id)
            .appendingPathComponent(descriptor.wineBinaryRelativePath)
    }

    /// Runtimes that decoded plus the metadata files that didn't. Corrupt
    /// files are reported, never deleted — the runtime payload is still on
    /// disk and silently filtering it would trigger a pointless re-download.
    public struct Listing: Sendable, Equatable {
        public var runtimes: [RuntimeDescriptor]
        public var corruptFiles: [URL]
    }

    public func listing() throws -> Listing {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runtimesDirectory.path) else {
            return Listing(runtimes: [], corruptFiles: [])
        }
        let children = try fm.contentsOfDirectory(
            at: runtimesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var runtimes: [RuntimeDescriptor] = []
        var corrupt: [URL] = []
        for dir in children {
            let metadata = dir.appendingPathComponent("runtime.json")
            guard fm.fileExists(atPath: metadata.path) else { continue }
            if let data = try? Data(contentsOf: metadata),
               let descriptor = try? JSONDecoder().decode(RuntimeDescriptor.self, from: data) {
                runtimes.append(descriptor)
            } else {
                corrupt.append(metadata)
            }
        }
        return Listing(
            runtimes: runtimes.sorted { $0.id < $1.id },
            corruptFiles: corrupt.sorted { $0.path < $1.path }
        )
    }

    public func installedRuntimes() throws -> [RuntimeDescriptor] {
        try listing().runtimes
    }

    public func descriptor(id: String) throws -> RuntimeDescriptor? {
        try installedRuntimes().first { $0.id == id }
    }

    /// The metadata file that marks a directory as an installed runtime.
    public static let metadataFileName = "runtime.json"

    /// Encodes `descriptor` into `directory`/runtime.json. Shared by `save`
    /// (into the installed location) and the installer (into a STAGING dir,
    /// so the payload and its metadata land together in a single rename
    /// rather than two separately-interruptible writes).
    public static func writeMetadata(_ descriptor: RuntimeDescriptor, into directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // .atomic: a crash mid-write must never leave a truncated runtime.json
        // (which listing() would then report as corrupt).
        try encoder.encode(descriptor).write(
            to: directory.appendingPathComponent(metadataFileName), options: [.atomic]
        )
    }

    public func save(_ descriptor: RuntimeDescriptor) throws {
        let dir = runtimeDirectory(id: descriptor.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.writeMetadata(descriptor, into: dir)
    }
}
