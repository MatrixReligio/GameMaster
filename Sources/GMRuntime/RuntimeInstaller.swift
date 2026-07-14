import Foundation
import GMModel
import GMSystem

public enum RuntimePhase: Sendable, Equatable {
    case downloading
    case verifying
    case unpacking
    case finishing
}

/// Downloads a manifest entry, verifies it, unpacks it into the runtime
/// store, and strips quarantine so wine can execute.
public struct RuntimeInstaller: Sendable {
    private let store: RuntimeStore
    private let downloader: any Downloading
    private let runner: any ProcessRunning
    private let quarantineRunner: any ProcessRunning

    /// `quarantineRunner` is separate from `runner` purely for testability;
    /// production callers pass the same SubprocessRunner for both.
    public init(
        store: RuntimeStore,
        downloader: any Downloading,
        runner: any ProcessRunning,
        quarantineRunner: (any ProcessRunning)? = nil
    ) {
        self.store = store
        self.downloader = downloader
        self.runner = runner
        self.quarantineRunner = quarantineRunner ?? runner
    }

    /// `afterSwap` is an injectable seam (default no-op) fired right after the
    /// payload is swapped into place, so tests can simulate a crash at that
    /// instant and assert the runtime is already complete (payload + metadata).
    public func install(
        entry: RuntimeManifest.Entry,
        progress: (@Sendable (RuntimePhase, Double) -> Void)?,
        afterSwap: @Sendable () throws -> Void = {}
    ) async throws -> RuntimeDescriptor {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("gamemaster-runtime-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        progress?(.downloading, 0)
        let archive = staging.appendingPathComponent(entry.url.lastPathComponent)
        try await downloader.download(from: entry.url, to: archive) { fraction in
            progress?(.downloading, fraction)
        }

        progress?(.verifying, 0)
        let digest = try SHA256.hexDigest(of: archive)
        guard digest == entry.sha256.lowercased() else {
            throw RuntimeError.checksumMismatch(expected: entry.sha256, actual: digest)
        }

        progress?(.unpacking, 0)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try await Archive.extractTar(archive, into: unpacked, runner: runner)
        guard fm.fileExists(atPath: unpacked.appendingPathComponent(entry.wineBinaryRelativePath).path) else {
            throw RuntimeError.archiveLayoutUnrecognized
        }

        progress?(.finishing, 0)
        try await Quarantine.remove(from: unpacked, runner: quarantineRunner)

        var descriptor = RuntimeDescriptor(
            id: entry.id,
            displayVersion: entry.displayVersion,
            wineBinaryRelativePath: entry.wineBinaryRelativePath,
            gptk: .none
        )
        if let gptkVersion = entry.bundledGPTKVersion {
            descriptor.gptk = .installed(version: gptkVersion)
        }
        if let dxmtVersion = entry.bundledDXMTVersion {
            descriptor.dxmt = .installed(version: dxmtVersion)
        }
        // Write runtime.json INTO the staging tree, so the single rename below
        // brings the payload and its metadata together. Writing metadata after
        // the swap (as before) left a window where a crash produced a payload
        // with no runtime.json — read as "missing" and pointlessly re-downloaded.
        try RuntimeStore.writeMetadata(descriptor, into: unpacked)

        let destination = await store.runtimeDirectory(id: entry.id)
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.replaceDirectory(at: destination, with: unpacked)
        try afterSwap()

        progress?(.finishing, 1)
        return descriptor
    }

    /// Cleans up after a crash that hit between replaceDirectory's two
    /// moves: a `.（id).old-*` backup left with no (or an empty) official
    /// directory is moved back into place — otherwise the runtime reads as
    /// missing forever and gets pointlessly re-downloaded. Stale backups
    /// next to a healthy directory are deleted. Call once at startup,
    /// before any install can create fresh backups.
    public static func recoverOrphanedBackups(in runtimesRoot: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runtimesRoot.path) else { return }
        let names = try fm.contentsOfDirectory(atPath: runtimesRoot.path)
        for name in names {
            guard name.hasPrefix("."),
                  let marker = name.range(of: ".old-", options: .backwards),
                  marker.lowerBound > name.index(after: name.startIndex)
            else { continue }
            let id = String(name[name.index(after: name.startIndex) ..< marker.lowerBound])
            let backup = runtimesRoot.appendingPathComponent(name, isDirectory: true)
            let official = runtimesRoot.appendingPathComponent(id, isDirectory: true)
            let officialContents = (try? fm.contentsOfDirectory(atPath: official.path)) ?? []
            if officialContents.isEmpty {
                try? fm.removeItem(at: official) // empty husk, if present
                try fm.moveItem(at: backup, to: official)
            } else {
                try fm.removeItem(at: backup)
            }
        }
    }

    /// Replaces `destination` with `source` without a window where neither
    /// exists: the old directory is renamed aside first, the new one moved
    /// in, and only then is the backup deleted. If moving the new directory
    /// fails, the backup is restored — a crash or error at any step leaves a
    /// working runtime on disk (the old remove-then-move lost the runtime
    /// when the second step died). `move` is injectable for failure tests.
    static func replaceDirectory(
        at destination: URL,
        with source: URL,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            try move(source, destination)
            return
        }
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).old-\(UUID().uuidString)")
        try move(destination, backup)
        do {
            try move(source, destination)
        } catch {
            try? move(backup, destination)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    /// Written to a runtime's root while a GPTK import swaps its nested `lib/`,
    /// and deleted once the metadata commit succeeds. If it survives to the next
    /// launch the import was interrupted BEFORE committing, so recovery rolls the
    /// old `lib/` back — otherwise a crash between the lib swap and the metadata
    /// save left the new lib with stale metadata (and the old
    /// remove-the-backup-first path left no way back at all).
    public struct GPTKImportTransaction: Codable, Equatable {
        public var libPath: String
        public var backupPath: String
        /// The gptk version this import is committing. Recovery compares it to
        /// the runtime's SAVED descriptor to tell a committed import (whose
        /// marker merely outlived the commit) from an interrupted one.
        public var targetVersion: String
        public init(libPath: String, backupPath: String, targetVersion: String) {
            self.libPath = libPath
            self.backupPath = backupPath
            self.targetVersion = targetVersion
        }
    }

    static let gptkImportMarkerName = ".gptk-import-txn.json"

    /// Cleans up GPTK imports whose transaction marker survived to the next
    /// launch. Recovery is EVIDENCE-BASED, not marker-presence-based: the
    /// metadata save is the commit point, but the marker/backup are deleted in
    /// separate steps after it, so a crash there can leave a marker on a runtime
    /// that DID commit. Rolling that back would strand new metadata over the old
    /// lib. So compare the saved descriptor's gptk version to the marker's
    /// target: if they match the import committed (keep the new lib, just clean
    /// up); otherwise it was interrupted before commit (restore the old lib).
    /// The marker lives at the runtime root, so recovery needs no knowledge of
    /// the nested wine layout. Call once at startup.
    public static func recoverInterruptedGPTKImports(in runtimesRoot: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: runtimesRoot.path) else { return }
        for runtimeName in try fm.contentsOfDirectory(atPath: runtimesRoot.path) {
            let runtimeDir = runtimesRoot.appendingPathComponent(runtimeName, isDirectory: true)
            let markerURL = runtimeDir.appendingPathComponent(gptkImportMarkerName)
            guard fm.fileExists(atPath: markerURL.path),
                  let data = try? Data(contentsOf: markerURL),
                  let txn = try? JSONDecoder().decode(GPTKImportTransaction.self, from: data)
            else { continue }
            let lib = URL(fileURLWithPath: txn.libPath)
            let backup = URL(fileURLWithPath: txn.backupPath)
            let committed = savedGPTKVersion(in: runtimeDir) == txn.targetVersion
            // Interrupted before commit → restore the old lib (if we got as far
            // as moving it aside). Committed → leave the new lib in place.
            if !committed, fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: lib)
                try? fm.moveItem(at: backup, to: lib)
            }
            try? fm.removeItem(at: backup)
            try? fm.removeItem(at: markerURL)
        }
    }

    /// The installed gptk version recorded in a runtime's saved `runtime.json`,
    /// or nil if absent/unreadable/not-installed.
    private static func savedGPTKVersion(in runtimeDir: URL) -> String? {
        let json = runtimeDir.appendingPathComponent("runtime.json")
        guard let data = try? Data(contentsOf: json),
              let descriptor = try? JSONDecoder().decode(RuntimeDescriptor.self, from: data),
              case let .installed(version) = descriptor.gptk
        else { return nil }
        return version
    }
}
