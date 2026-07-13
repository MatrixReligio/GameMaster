import Foundation
import Testing
@testable import GMRuntime

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-replace-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Replacing an installed runtime must never destroy the old one first:
/// the old directory is renamed aside, the new one moved in, and only then
/// is the backup deleted — a failure at any step leaves a working runtime.
@Suite("RuntimeInstaller atomic replace")
struct AtomicReplaceTests {
    @Test func replaceSwapsContentAndCleansUpBackup() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("runtimes/rt", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("wine"))
        let incoming = root.appendingPathComponent("staging/unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: incoming.appendingPathComponent("wine"))

        try RuntimeInstaller.replaceDirectory(at: destination, with: incoming)

        #expect(try String(contentsOf: destination.appendingPathComponent("wine"), encoding: .utf8) == "new")
        // No backup corpses left next to the runtime.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(siblings == ["rt"])
    }

    @Test func failedIncomingMoveRestoresOldRuntime() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("runtimes/rt", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("wine"))
        let incoming = root.appendingPathComponent("staging/unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: incoming.appendingPathComponent("wine"))

        // The move of the NEW directory into place dies (disk full, sandbox…).
        struct MoveFailure: Error {}
        #expect(throws: MoveFailure.self) {
            try RuntimeInstaller.replaceDirectory(at: destination, with: incoming) { from, to in
                if from.path == incoming.path {
                    throw MoveFailure()
                }
                try FileManager.default.moveItem(at: from, to: to)
            }
        }

        // The old runtime is back in place, intact.
        #expect(try String(contentsOf: destination.appendingPathComponent("wine"), encoding: .utf8) == "old")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(siblings == ["rt"])
    }

    /// A crash between the two moves of replaceDirectory leaves the backup
    /// on disk and the official directory missing — the runtime would stay
    /// broken forever. Startup recovery must move the backup back.
    @Test func recoversOrphanedBackupOnStartup() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimes = root.appendingPathComponent("runtimes", isDirectory: true)

        // Crash scenario A: official dir gone, backup orphaned.
        let orphan = runtimes.appendingPathComponent(".sikarugir-10.0-6-dxmt-0.80.old-AAAA", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: orphan.appendingPathComponent("wine"))

        // Crash scenario B: official dir healthy, stale backup left behind.
        let healthy = runtimes.appendingPathComponent("gptk-3.0-3", isDirectory: true)
        try FileManager.default.createDirectory(at: healthy, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: healthy.appendingPathComponent("wine"))
        let stale = runtimes.appendingPathComponent(".gptk-3.0-3.old-BBBB", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("wine"))

        try RuntimeInstaller.recoverOrphanedBackups(in: runtimes)

        // A: restored under its official name.
        let restored = runtimes.appendingPathComponent("sikarugir-10.0-6-dxmt-0.80")
        #expect(try String(contentsOf: restored.appendingPathComponent("wine"), encoding: .utf8) == "wine")
        // B: healthy dir untouched, stale backup removed.
        #expect(try String(contentsOf: healthy.appendingPathComponent("wine"), encoding: .utf8) == "current")
        let names = try FileManager.default.contentsOfDirectory(atPath: runtimes.path).sorted()
        #expect(names == ["gptk-3.0-3", "sikarugir-10.0-6-dxmt-0.80"])
    }

    @Test func recoveryIsANoOpWithoutBackupsOrDirectory() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Missing runtimes dir must not throw (first launch).
        try RuntimeInstaller.recoverOrphanedBackups(in: root.appendingPathComponent("runtimes"))
    }

    @Test func firstInstallJustMovesIntoPlace() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("runtimes/rt", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let incoming = root.appendingPathComponent("staging/unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: incoming.appendingPathComponent("wine"))

        try RuntimeInstaller.replaceDirectory(at: destination, with: incoming)
        #expect(try String(contentsOf: destination.appendingPathComponent("wine"), encoding: .utf8) == "new")
    }
}
