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

    public func list() throws -> [Bottle] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bottlesDirectory.path) else { return [] }
        let children = try fm.contentsOfDirectory(
            at: bottlesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return children.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("bottle.json")) else {
                return nil
            }
            return try? decoder.decode(Bottle.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ bottle: Bottle) throws {
        try write(bottle)
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
        try encoder.encode(bottle).write(to: dir.appendingPathComponent("bottle.json"))
    }
}
