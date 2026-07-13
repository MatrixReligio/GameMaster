import Foundation
import GMModel

public enum BottleError: Error, LocalizedError, Equatable {
    case bottleNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .bottleNotFound:
            String(localized: "This bottle no longer exists on disk.")
        }
    }
}

/// Owns the `bottles/` directory under the app-support root. Each bottle is
/// `bottles/<uuid>/` containing `bottle.json` and the wine prefix in `prefix/`.
public actor BottleStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var bottlesDirectory: URL {
        root.appendingPathComponent("bottles", isDirectory: true)
    }

    public func directory(of bottle: Bottle) -> URL {
        bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
    }

    public func prefixDirectory(of bottle: Bottle) -> URL {
        directory(of: bottle).appendingPathComponent("prefix", isDirectory: true)
    }

    public func create(name: String, runtimeID: String?) throws -> Bottle {
        let bottle = Bottle(name: name, runtimeID: runtimeID)
        let dir = directory(of: bottle)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("prefix", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write(bottle)
        return bottle
    }

    /// Bottles that decoded plus the metadata files that didn't. Corrupt
    /// files are reported, never deleted — the prefix (the user's games)
    /// is still on disk and recoverable by hand.
    public struct Listing: Sendable, Equatable {
        public var bottles: [Bottle]
        public var corruptFiles: [URL]
    }

    public func listing() throws -> Listing {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bottlesDirectory.path) else {
            return Listing(bottles: [], corruptFiles: [])
        }
        let children = try fm.contentsOfDirectory(
            at: bottlesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = Self.decoder
        var bottles: [Bottle] = []
        var corrupt: [URL] = []
        for dir in children {
            let file = dir.appendingPathComponent("bottle.json")
            guard fm.fileExists(atPath: file.path) else { continue }
            if let data = try? Data(contentsOf: file),
               let bottle = try? decoder.decode(Bottle.self, from: data) {
                bottles.append(bottle)
            } else {
                corrupt.append(file)
            }
        }
        return Listing(
            bottles: bottles.sorted { $0.createdAt < $1.createdAt },
            corruptFiles: corrupt.sorted { $0.path < $1.path }
        )
    }

    public func list() throws -> [Bottle] {
        try listing().bottles
    }

    /// Transactional read-modify-write: reads the bottle's CURRENT state
    /// inside the actor, applies `mutate`, and persists. Long-running tasks
    /// (installs) and the settings sheet must use this instead of saving a
    /// whole snapshot taken earlier — a stale snapshot save silently drops
    /// every change made in between.
    @discardableResult
    public func update(id: UUID, _ mutate: @Sendable (inout Bottle) throws -> Void) throws -> Bottle {
        var bottle = try load(id: id)
        try mutate(&bottle)
        try write(bottle)
        return bottle
    }

    public func save(_ bottle: Bottle) throws {
        // Refuse to resurrect a deleted bottle: a save landing after delete
        // would recreate bottle.json without a live prefix (a "ghost").
        guard FileManager.default.fileExists(atPath: directory(of: bottle).path) else {
            throw BottleError.bottleNotFound(bottle.id)
        }
        try write(bottle)
    }

    private func load(id: UUID) throws -> Bottle {
        let file = bottlesDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("bottle.json")
        guard let data = try? Data(contentsOf: file),
              let bottle = try? Self.decoder.decode(Bottle.self, from: data)
        else {
            throw BottleError.bottleNotFound(id)
        }
        return bottle
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func delete(id: UUID) throws {
        let dir = bottlesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private func write(_ bottle: Bottle) throws {
        let dir = directory(of: bottle)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // .atomic: a crash mid-write must never leave a truncated bottle.json
        // (which list() would then report as corrupt).
        try encoder.encode(bottle).write(to: dir.appendingPathComponent("bottle.json"), options: [.atomic])
    }
}
