import Foundation
import GMModel

/// Performs Apple's documented MetalFX preparation for a runtime + prefix:
/// activate nvngx-on-metalfx.{so,dll} as nvngx.{so,dll} and copy nvngx.dll +
/// nvapi64.dll into the prefix's system32. Idempotent, and non-destructive to
/// the runtime: the `-on-metalfx` originals are copied, never moved, so the
/// shared runtime template stays intact and reusable across bottles.
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

        // Copy — not move — so the runtime template keeps its `-on-metalfx`
        // originals: the runtime is shared, and moving would consume it (and
        // never restore on disable). Skip when the target already exists, which
        // keeps this idempotent and leaves a runtime that already ships stock
        // nvngx.{so,dll} untouched.
        let activations = [
            ("wine/x86_64-unix/nvngx-on-metalfx.so", "wine/x86_64-unix/nvngx.so"),
            ("wine/x86_64-windows/nvngx-on-metalfx.dll", "wine/x86_64-windows/nvngx.dll")
        ]
        for (from, to) in activations {
            let source = lib.appendingPathComponent(from)
            let target = lib.appendingPathComponent(to)
            if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) {
                try fm.copyItem(at: source, to: target)
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
