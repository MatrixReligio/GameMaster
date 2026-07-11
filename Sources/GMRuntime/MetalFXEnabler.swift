import Foundation
import GMModel

/// Performs Apple's documented MetalFX preparation for a runtime + prefix:
/// rename nvngx-on-metalfx.{so,dll} to nvngx.{so,dll} and copy nvngx.dll +
/// nvapi64.dll into the prefix's system32. Idempotent.
public struct MetalFXEnabler: Sendable {
    private let store: RuntimeStore

    public init(store: RuntimeStore) {
        self.store = store
    }

    public func prepare(runtimeID: String, prefix: URL) async throws {
        guard let descriptor = try await store.descriptor(id: runtimeID) else {
            throw RuntimeError.runtimeNotInstalled(id: runtimeID)
        }
        let wineBinary = await store.wineBinary(for: descriptor)
        let lib = wineBinary.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib", isDirectory: true)
        let fm = FileManager.default

        let renames = [
            ("wine/x86_64-unix/nvngx-on-metalfx.so", "wine/x86_64-unix/nvngx.so"),
            ("wine/x86_64-windows/nvngx-on-metalfx.dll", "wine/x86_64-windows/nvngx.dll")
        ]
        for (from, to) in renames {
            let source = lib.appendingPathComponent(from)
            let target = lib.appendingPathComponent(to)
            if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) {
                try fm.moveItem(at: source, to: target)
            }
        }

        let system32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        for dll in ["nvngx.dll", "nvapi64.dll"] {
            let source = lib.appendingPathComponent("wine/x86_64-windows/\(dll)")
            let target = system32.appendingPathComponent(dll)
            guard fm.fileExists(atPath: source.path) else { continue }
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: source, to: target)
        }
    }
}
