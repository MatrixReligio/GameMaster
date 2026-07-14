import Foundation
import GMModel
import Testing
@testable import GMLaunch

@Suite("WineLauncher DXMT prefix support")
struct WineLauncherDXMTConcurrencyTests {
    /// context() mirrors the runtime's winemetal.dll into the prefix on EVERY
    /// wine op, so two programs launching in one bottle run it concurrently on
    /// the same prefix. The placement must be atomic: every call lands the full
    /// DLL and leaves no temp (the old removeItem→copyItem left it momentarily
    /// gone, and a concurrent reader could miss it).
    @Test func concurrentEnsureDXMTPrefixSupportIsAtomic() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-dxmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Fake wine root: <root>/bin/wine64 and <root>/lib/wine/x86_64-windows/.
        let wineRoot = dir.appendingPathComponent("wine")
        let bin = wineRoot.appendingPathComponent("bin")
        let winDir = wineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        let wineBinary = bin.appendingPathComponent("wine64")
        try Data("wine".utf8).write(to: wineBinary)
        let payload = String(repeating: "W", count: 64 * 1024)
        try Data(payload.utf8).write(to: winDir.appendingPathComponent("winemetal.dll"))

        let prefix = dir.appendingPathComponent("prefix")
        let descriptor = RuntimeDescriptor(
            id: "rt",
            displayVersion: "test",
            wineBinaryRelativePath: "wine/bin/wine64",
            dxmt: .installed(version: "0.80")
        )

        // Placement is now throwing, but AtomicFile tolerates same-source races,
        // so 32 concurrent placers all succeed — a spurious throw fails here.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    try WineLauncher.ensureDXMTPrefixSupport(
                        runtime: descriptor, wineBinary: wineBinary, prefix: prefix
                    )
                }
            }
            try await group.waitForAll()
        }

        let target = prefix.appendingPathComponent("drive_c/windows/system32/winemetal.dll")
        #expect(try String(contentsOf: target, encoding: .utf8) == payload)
        let system32 = target.deletingLastPathComponent()
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: system32.path)
            .filter { $0.contains(".gm-") }
        #expect(leftovers.isEmpty)
    }
}
