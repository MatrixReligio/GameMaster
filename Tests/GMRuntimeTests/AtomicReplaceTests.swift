import Foundation
import GMModel
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

@Suite("GPTK import recovery")
struct GPTKImportRecoveryTests {
    /// Lays out an interrupted-import runtime: a `lib/` with the NEW content, a
    /// `.lib.old-*` backup with the OLD content, a marker targeting `version`,
    /// and a saved `runtime.json` recording `savedGPTK`. Returns the lib URL.
    private struct Staged {
        let runtimesRoot: URL
        let lib: URL
        let backup: URL
        let marker: URL
    }

    private func stageInterrupted(
        in dir: URL, targetVersion: String, savedGPTK: GPTKStatus
    ) throws -> Staged {
        let runtimesRoot = dir.appendingPathComponent("runtimes")
        let runtimeDir = runtimesRoot.appendingPathComponent("rt")
        let wineRoot = runtimeDir.appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine")
        let lib = wineRoot.appendingPathComponent("lib")
        let backup = wineRoot.appendingPathComponent(".lib.old-ABC")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: lib.appendingPathComponent("d3dmetal"))
        try Data("old".utf8).write(to: backup.appendingPathComponent("d3dmetal"))
        let descriptor = RuntimeDescriptor(
            id: "rt", displayVersion: "test", wineBinaryRelativePath: "x", gptk: savedGPTK
        )
        try JSONEncoder().encode(descriptor).write(to: runtimeDir.appendingPathComponent("runtime.json"))
        let marker = runtimeDir.appendingPathComponent(".gptk-import-txn.json")
        try JSONEncoder().encode(RuntimeInstaller.GPTKImportTransaction(
            libPath: lib.path, backupPath: backup.path, targetVersion: targetVersion
        )).write(to: marker)
        return Staged(runtimesRoot: runtimesRoot, lib: lib, backup: backup, marker: marker)
    }

    /// Interrupted BEFORE the metadata commit (saved gptk still old): recovery
    /// restores the OLD lib so the runtime and its metadata agree.
    @Test func recoverRollsBackAnImportInterruptedBeforeCommit() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try stageInterrupted(in: dir, targetVersion: "3.0", savedGPTK: .none)

        try RuntimeInstaller.recoverInterruptedGPTKImports(in: staged.runtimesRoot)

        #expect(try String(contentsOf: staged.lib.appendingPathComponent("d3dmetal"), encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: staged.backup.path))
        #expect(!FileManager.default.fileExists(atPath: staged.marker.path))
    }

    /// The crash-safety case the review caught: the metadata commit already
    /// landed (saved gptk == target) but the marker outlived it. Recovery must
    /// KEEP the new lib — rolling back would strand new metadata over the old
    /// lib — and just clean up the marker + backup.
    @Test func recoverKeepsACommittedImportWhoseMarkerSurvived() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try stageInterrupted(in: dir, targetVersion: "3.0", savedGPTK: .installed(version: "3.0"))

        try RuntimeInstaller.recoverInterruptedGPTKImports(in: staged.runtimesRoot)

        #expect(try String(contentsOf: staged.lib.appendingPathComponent("d3dmetal"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.backup.path))
        #expect(!FileManager.default.fileExists(atPath: staged.marker.path))
    }

    /// The brick the last review caught: re-importing the SAME gptk version and
    /// crashing between moving the old lib aside and moving the new one in — so
    /// `lib/` is MISSING. The saved version already equals the target, so a
    /// version-only "committed?" test wrongly concludes it committed, keeps the
    /// (nonexistent) new lib, and deletes the backup — stranding the runtime
    /// with no lib at all. Recovery must notice the missing lib and restore from
    /// the backup regardless of the version match.
    @Test func recoverRestoresLibWhenNewLibNeverLandedEvenIfVersionMatches() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A repair re-import of 3.0 over an already-3.0 runtime: versions match.
        let staged = try stageInterrupted(in: dir, targetVersion: "3.0", savedGPTK: .installed(version: "3.0"))
        // Crash BETWEEN the two moves: the old lib is aside in the backup and
        // the new lib never landed — lib/ is gone.
        try FileManager.default.removeItem(at: staged.lib)

        try RuntimeInstaller.recoverInterruptedGPTKImports(in: staged.runtimesRoot)

        // lib/ is back (restored from the backup) — the runtime isn't bricked.
        #expect(try String(contentsOf: staged.lib.appendingPathComponent("d3dmetal"), encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: staged.backup.path))
        #expect(!FileManager.default.fileExists(atPath: staged.marker.path))
    }

    /// If the rollback move itself fails (disk full, sandbox, a locked file),
    /// recovery must NOT delete the backup and marker — that would destroy the
    /// only evidence and strand the runtime with no lib. The remnants survive so
    /// the next launch retries.
    @Test func recoveryKeepsEvidenceWhenRestoreFails() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Interrupted before commit (saved gptk still .none) → must roll back.
        let staged = try stageInterrupted(in: dir, targetVersion: "3.0", savedGPTK: .none)
        struct MoveFailure: Error {}

        try RuntimeInstaller.recoverInterruptedGPTKImports(in: staged.runtimesRoot) { _, _ in
            throw MoveFailure()
        }

        #expect(FileManager.default.fileExists(atPath: staged.backup.path))
        #expect(FileManager.default.fileExists(atPath: staged.marker.path))
    }

    /// A committed runtime has no marker, so recovery leaves it untouched.
    @Test func recoverLeavesACommittedRuntimeAlone() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtimesRoot = dir.appendingPathComponent("runtimes")
        let lib = runtimesRoot.appendingPathComponent("rt/wine/lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("committed".utf8).write(to: lib.appendingPathComponent("d3dmetal"))

        try RuntimeInstaller.recoverInterruptedGPTKImports(in: runtimesRoot)

        #expect(try String(contentsOf: lib.appendingPathComponent("d3dmetal"), encoding: .utf8) == "committed")
    }
}
