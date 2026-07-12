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

    public func install(
        entry: RuntimeManifest.Entry,
        progress: (@Sendable (RuntimePhase, Double) -> Void)?
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

        // Move into place atomically: never leave a half-copied runtime.
        let destination = await store.runtimeDirectory(id: entry.id)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: unpacked, to: destination)

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
        try await store.save(descriptor)
        progress?(.finishing, 1)
        return descriptor
    }
}
