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

    public func installedRuntimes() throws -> [RuntimeDescriptor] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runtimesDirectory.path) else { return [] }
        let children = try fm.contentsOfDirectory(
            at: runtimesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return children.compactMap { dir in
            let metadata = dir.appendingPathComponent("runtime.json")
            guard let data = try? Data(contentsOf: metadata) else { return nil }
            return try? JSONDecoder().decode(RuntimeDescriptor.self, from: data)
        }
        .sorted { $0.id < $1.id }
    }

    public func descriptor(id: String) throws -> RuntimeDescriptor? {
        try installedRuntimes().first { $0.id == id }
    }

    public func save(_ descriptor: RuntimeDescriptor) throws {
        let dir = runtimeDirectory(id: descriptor.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(descriptor).write(to: dir.appendingPathComponent("runtime.json"))
    }

}
