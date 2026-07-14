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
            try Self.activateShim(
                from: lib.appendingPathComponent(from),
                to: lib.appendingPathComponent(to),
                using: fm
            )
        }

        let system32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        // MetalFX needs the shim on BOTH sides: the unix nvngx.so (loaded by
        // wine) and the windows nvngx.dll (loaded by the game). If the runtime
        // provides either neither directly nor via the activation above, MetalFX
        // cannot work — fail clearly instead of silently "succeeding" half
        // prepared. nvapi64.dll is auxiliary and copied best-effort.
        let requiredShims = ["wine/x86_64-unix/nvngx.so", "wine/x86_64-windows/nvngx.dll"]
        for shim in requiredShims where !fm.fileExists(atPath: lib.appendingPathComponent(shim).path) {
            throw RuntimeError.metalFXShimMissing
        }
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

    /// Activates one `-on-metalfx` shim (`source`) as `target` in the SHARED
    /// runtime, non-destructively and atomically. The runtime is contended: two
    /// bottles can launch at once and each prepares MetalFX on it. Copying
    /// straight to `target` would let a concurrent reader observe a half-written
    /// shim, and two writers collide (the loser throwing EEXIST would fail a
    /// launch). So the copy lands in a uniquely-named temp beside the target and
    /// is moved into place with a single atomic rename — `target` only ever
    /// appears complete. The fast-path skip keeps re-prepares cheap and idempotent.
    static func activateShim(from source: URL, to target: URL, using fm: FileManager) throws {
        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { return }
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).gm-activate-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        do {
            try fm.moveItem(at: temp, to: target)
        } catch {
            // A concurrent prepare won the race and already placed the target
            // (identical content — both come from the same immutable source).
            // Drop our redundant temp; only a still-missing target is a real
            // failure worth surfacing.
            try? fm.removeItem(at: temp)
            if !fm.fileExists(atPath: target.path) {
                throw error
            }
        }
    }
}
