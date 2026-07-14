import Foundation
import GMModel
import Testing
@testable import GMRuntime

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-metalfx-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("MetalFXEnabler")
struct MetalFXEnablerTests {
    @Test func preparesNvngxFilesPerAppleReadme() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let unixDir = lib.appendingPathComponent("wine/x86_64-unix")
        let winDir = lib.appendingPathComponent("wine/x86_64-windows")
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data("so".utf8).write(to: unixDir.appendingPathComponent("nvngx-on-metalfx.so"))
        try Data("dll".utf8).write(to: winDir.appendingPathComponent("nvngx-on-metalfx.dll"))
        try Data("nvapi".utf8).write(to: winDir.appendingPathComponent("nvapi64.dll"))

        let prefix = dir.appendingPathComponent("prefix")
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)

        let enabler = MetalFXEnabler(store: store)
        try await enabler.prepare(runtimeID: "rt", prefix: prefix)

        // Renamed per Apple's Read Me…
        #expect(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("nvngx.so").path))
        #expect(FileManager.default.fileExists(atPath: winDir.appendingPathComponent("nvngx.dll").path))
        // …and both dlls copied into the prefix's system32.
        #expect(try String(
            contentsOf: system32.appendingPathComponent("nvngx.dll"), encoding: .utf8
        ) == "dll")
        #expect(try String(
            contentsOf: system32.appendingPathComponent("nvapi64.dll"), encoding: .utf8
        ) == "nvapi")

        // Idempotent: preparing again must not fail.
        try await enabler.prepare(runtimeID: "rt", prefix: prefix)
    }

    /// The runtime is shared by every bottle, so preparing MetalFX must not
    /// consume its template: the `nvngx-on-metalfx.*` originals must survive
    /// (copied, not moved), so the runtime stays reusable and restorable.
    @Test func prepareIsNonDestructiveToRuntimeTemplate() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let unixDir = lib.appendingPathComponent("wine/x86_64-unix")
        let winDir = lib.appendingPathComponent("wine/x86_64-windows")
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data("so".utf8).write(to: unixDir.appendingPathComponent("nvngx-on-metalfx.so"))
        try Data("dll".utf8).write(to: winDir.appendingPathComponent("nvngx-on-metalfx.dll"))

        let prefix = dir.appendingPathComponent("prefix")
        try await MetalFXEnabler(store: store).prepare(runtimeID: "rt", prefix: prefix)

        // The activated copies exist…
        #expect(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("nvngx.so").path))
        #expect(FileManager.default.fileExists(atPath: winDir.appendingPathComponent("nvngx.dll").path))
        // …and the template originals are still there (not moved away).
        #expect(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("nvngx-on-metalfx.so").path))
        #expect(FileManager.default.fileExists(atPath: winDir.appendingPathComponent("nvngx-on-metalfx.dll").path))
    }

    /// If MetalFX is requested but the runtime provides no nvngx shim at all
    /// (neither the activated `nvngx.dll` nor the `-on-metalfx` source to
    /// activate), prep must fail clearly rather than silently "succeeding" with
    /// a feature that cannot work.
    @Test func prepareThrowsWhenMetalFXShimMissing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let winDir = lib.appendingPathComponent("wine/x86_64-windows")
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        // Deliberately no nvngx.dll and no nvngx-on-metalfx.dll.

        let prefix = dir.appendingPathComponent("prefix")
        await #expect(throws: RuntimeError.self) {
            try await MetalFXEnabler(store: store).prepare(runtimeID: "rt", prefix: prefix)
        }
    }

    /// MetalFX needs BOTH the unix `nvngx.so` (loaded by wine) and the windows
    /// `nvngx.dll` (loaded by the game). A runtime with only the windows shim
    /// must still fail clearly, not silently "succeed" half-prepared.
    @Test func prepareThrowsWhenUnixShimMissing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let winDir = lib.appendingPathComponent("wine/x86_64-windows")
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: winDir.appendingPathComponent("nvngx.dll"))
        // Windows shim present, but no x86_64-unix/nvngx.so.

        let prefix = dir.appendingPathComponent("prefix")
        await #expect(throws: RuntimeError.self) {
            try await MetalFXEnabler(store: store).prepare(runtimeID: "rt", prefix: prefix)
        }
    }

    /// Two bottles launching at once both prepare MetalFX on the SAME shared
    /// runtime, so the nvngx activation is a contended write. Activation places
    /// each shim through a uniquely-named temp + atomic move, so a concurrent
    /// prepare can never expose a half-written `nvngx.*` and the race loser
    /// tolerates the winner's file instead of throwing. Every concurrent
    /// prepare must succeed, leave the activated shims holding the FULL source
    /// content, and leave no activation temp behind.
    ///
    /// Note: on APFS `copyItem` clones atomically, so this asserts the
    /// invariants (no throw / full content / no temp residue) rather than
    /// reproducing the race, which is not observable on a copy-on-write volume.
    @Test func concurrentPrepareActivatesAtomically() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let unixDir = lib.appendingPathComponent("wine/x86_64-unix")
        let winDir = lib.appendingPathComponent("wine/x86_64-windows")
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        let soPayload = String(repeating: "S", count: 4096)
        let dllPayload = String(repeating: "D", count: 4096)
        try Data(soPayload.utf8).write(to: unixDir.appendingPathComponent("nvngx-on-metalfx.so"))
        try Data(dllPayload.utf8).write(to: winDir.appendingPathComponent("nvngx-on-metalfx.dll"))

        let enabler = MetalFXEnabler(store: store)
        // Share the runtime lib (the contended activation), one prefix per bottle.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 32 {
                let prefix = dir.appendingPathComponent("prefix-\(index)")
                group.addTask { try await enabler.prepare(runtimeID: "rt", prefix: prefix) }
            }
            try await group.waitForAll() // rethrows if ANY concurrent prepare threw
        }

        // Activated shims exist with the FULL source content (never truncated).
        #expect(try String(
            contentsOf: unixDir.appendingPathComponent("nvngx.so"), encoding: .utf8
        ) == soPayload)
        #expect(try String(
            contentsOf: winDir.appendingPathComponent("nvngx.dll"), encoding: .utf8
        ) == dllPayload)
        // No activation temp was left behind in either lib dir.
        for probe in [unixDir, winDir] {
            let leftovers = try FileManager.default
                .contentsOfDirectory(atPath: probe.path)
                .filter { $0.contains(".gm-activate-") }
            #expect(leftovers.isEmpty)
        }
    }

    /// Two programs launching in ONE bottle both prepare MetalFX on the SAME
    /// prefix, so the system32 copy is contended too. It must be atomic: every
    /// concurrent prepare succeeds, the prefix DLLs hold full content, and no
    /// temp is left behind (the old removeItem→copyItem raced here).
    @Test func concurrentPrepareOnOnePrefixCopiesSystem32Atomically() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let unixDir = lib.appendingPathComponent("wine/x86_64-unix")
        let winDir = lib.appendingPathComponent("wine/x86_64-windows")
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data("so".utf8).write(to: unixDir.appendingPathComponent("nvngx-on-metalfx.so"))
        let dllPayload = String(repeating: "D", count: 64 * 1024)
        let nvapiPayload = String(repeating: "A", count: 64 * 1024)
        try Data(dllPayload.utf8).write(to: winDir.appendingPathComponent("nvngx-on-metalfx.dll"))
        try Data(nvapiPayload.utf8).write(to: winDir.appendingPathComponent("nvapi64.dll"))

        let prefix = dir.appendingPathComponent("shared-prefix") // ONE prefix, contended
        let enabler = MetalFXEnabler(store: store)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask { try await enabler.prepare(runtimeID: "rt", prefix: prefix) }
            }
            try await group.waitForAll()
        }

        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        #expect(try String(contentsOf: system32.appendingPathComponent("nvngx.dll"), encoding: .utf8) == dllPayload)
        #expect(try String(contentsOf: system32.appendingPathComponent("nvapi64.dll"), encoding: .utf8) == nvapiPayload)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: system32.path)
            .filter { $0.contains(".gm-") }
        #expect(leftovers.isEmpty)
    }
}
