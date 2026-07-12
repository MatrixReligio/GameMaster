import Foundation
import GMBottles
import GMLaunch
import GMModel
import GMSystem

public enum InstallPhase: Sendable, Equatable {
    case downloading
    case installing
    case configuring
    case done
}

public enum InstallError: Error, LocalizedError, Equatable {
    case installerFailed(name: String, exitCode: Int32)
    case programNotFound(name: String, path: String)
    case bootstrapTimedOut(name: String)

    public var errorDescription: String? {
        switch self {
        case let .installerFailed(name, exitCode):
            String(localized: "The \(name) installer failed (exit code \(exitCode)). Please try again.")
        case let .programNotFound(name, _):
            String(localized: "The \(name) installer finished but the program wasn't found. Please try again.")
        case let .bootstrapTimedOut(name):
            String(localized: "\(name) did not finish downloading in time. Check your connection and try again.")
        }
    }
}

/// Orchestrates a one-click install: download the vendor installer, run it
/// silently in the bottle, drop config files, and register the program.
public struct AppInstaller: Sendable {
    private let downloader: any Downloading
    private let launcher: WineLauncher
    private let bottleStore: BottleStore
    /// How long the bootstrap download may show zero activity before the
    /// client is presumed dead (e.g. "Failed to load steamui.dll" and exit)
    /// and gets relaunched. Injectable so tests don't wait a real minute.
    private let bootstrapStallSeconds: TimeInterval

    public init(
        downloader: any Downloading,
        launcher: WineLauncher,
        bottleStore: BottleStore,
        bootstrapStallSeconds: TimeInterval = 60
    ) {
        self.downloader = downloader
        self.launcher = launcher
        self.bottleStore = bottleStore
        self.bootstrapStallSeconds = bootstrapStallSeconds
    }

    @discardableResult
    public func install(
        _ entry: InstallerCatalog.Entry,
        into bottle: Bottle,
        progress: (@Sendable (InstallPhase, Double) -> Void)?
    ) async throws -> Program {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("gamemaster-install-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        progress?(.downloading, 0)
        let installerFile = staging.appendingPathComponent(entry.installerFileName)
        try await downloader.download(from: entry.downloadURL, to: installerFile) { fraction in
            progress?(.downloading, fraction)
        }

        progress?(.installing, 0)
        let result = try await launcher.run(
            exe: installerFile,
            arguments: entry.silentArguments,
            in: bottle,
            wait: true
        )
        guard result.exitCode == 0 else {
            throw InstallError.installerFailed(name: entry.name, exitCode: result.exitCode)
        }

        progress?(.configuring, 0)
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        // Confirm the installer actually produced the program before we pin it,
        // so a silently-broken install doesn't register a dead entry.
        let installedExe = WindowsPath.toUnix(entry.installedWindowsPath, prefix: prefix)
        guard fm.fileExists(atPath: installedExe.path) else {
            throw InstallError.programNotFound(name: entry.name, path: entry.installedWindowsPath)
        }

        // Bootstrap the real client (under the current 32-bit-capable runtime)
        // and install the web-helper wrapper so the Steam UI isn't black.
        try await bootstrapAndInstallWrapper(entry: entry, bottle: bottle, prefix: prefix, progress: progress)

        for config in entry.configFiles {
            let unix = WindowsPath.toUnix(config.windowsPath, prefix: prefix)
            try fm.createDirectory(at: unix.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.contents.write(to: unix, atomically: true, encoding: .utf8)
        }

        let program = Program(
            name: entry.name,
            windowsPath: entry.installedWindowsPath,
            arguments: entry.launchArguments,
            pinned: true
        )
        let bottleDirectory = await bottleStore.directory(of: bottle)
        ProgramIconStore.extractAndStore(
            exe: installedExe,
            programID: program.id,
            bottleDirectory: bottleDirectory
        )
        var updated = bottle
        // Switch the bottle to the run runtime (Steam bootstraps under GPTK but
        // runs under a newer Wine whose CEF handshake actually completes).
        if let runRuntimeID = entry.runRuntimeID {
            updated.runtimeID = runRuntimeID
        }
        Self.applyRunTuning(entry.runTuning, to: &updated)
        updated.programs.removeAll { $0.windowsPath == entry.installedWindowsPath }
        updated.programs.append(program)
        try await bottleStore.save(updated)

        progress?(.done, 1)
        return program
    }

    /// Upgrades an already-installed program's bottle to its dual-runtime config:
    /// bootstraps if needed, installs the web-helper wrapper, and switches the
    /// bottle to the run runtime. For bottles created before that flow existed
    /// (a Steam pinned under GPTK that would otherwise loop). The run runtime
    /// must already be installed. Returns the updated bottle.
    @discardableResult
    public func migrate(
        _ entry: InstallerCatalog.Entry,
        in bottle: Bottle,
        progress: (@Sendable (InstallPhase, Double) -> Void)?
    ) async throws -> Bottle {
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        try await bootstrapAndInstallWrapper(entry: entry, bottle: bottle, prefix: prefix, progress: progress)
        var updated = bottle
        if let runRuntimeID = entry.runRuntimeID {
            updated.runtimeID = runRuntimeID
        }
        Self.applyRunTuning(entry.runTuning, to: &updated)
        try await bottleStore.save(updated)
        progress?(.done, 1)
        return updated
    }

    /// Applies the catalog's per-runtime performance tuning to the bottle
    /// (e.g. msync + Rosetta AVX for the Sikarugir/DXMT Steam runtime).
    private static func applyRunTuning(_ tuning: InstallerCatalog.RunTuning?, to bottle: inout Bottle) {
        guard let tuning else { return }
        if let sync = tuning.sync {
            bottle.settings.sync = sync
        }
        if let advertiseAVX = tuning.advertiseAVX {
            bottle.settings.advertiseAVX = advertiseAVX
        }
    }

    /// Bootstrap the client (if not already), then apply the run-runtime binary
    /// fixups: the CEF web-helper wrapper (black UI) and the service stub (Steam
    /// Service Error dialog). Shared by first install and later migration.
    private func bootstrapAndInstallWrapper(
        entry: InstallerCatalog.Entry,
        bottle: Bottle,
        prefix: URL,
        progress: (@Sendable (InstallPhase, Double) -> Void)?
    ) async throws {
        if entry.bootstrap != nil {
            let exe = WindowsPath.toUnix(entry.installedWindowsPath, prefix: prefix)
            try await runBootstrap(entry: entry, exe: exe, bottle: bottle, prefix: prefix, progress: progress)
        }
        try Self.applySteamBinaryFixups(entry: entry, prefix: prefix)
    }

    /// Installs the CEF wrapper and service stub for `entry` into `prefix`.
    /// Idempotent; safe to re-run on every launch (see `AppState.launch`).
    static func applySteamBinaryFixups(entry: InstallerCatalog.Entry, prefix: URL) throws {
        if let wrapper = entry.webhelperWrapper,
           let resource = SteamWebHelperWrapper.bundledResource(named: wrapper.wrapperResourceName) {
            try SteamWebHelperWrapper.install(spec: wrapper, prefix: prefix, wrapperResource: resource)
        }
        if let stub = entry.serviceStub,
           let resource = SteamServiceStub.bundledResource(named: stub.stubResourceName) {
            try SteamServiceStub.install(spec: stub, prefix: prefix, stubResource: resource)
        }
    }

    /// Launches the freshly-installed program (under `bottle`'s current runtime)
    /// and polls until its readiness file reaches the expected size, then stops
    /// it. This is Steam's first client download; it must complete before we
    /// switch the bottle to a runtime whose 32-bit service crashes mid-download.
    private func runBootstrap(
        entry: InstallerCatalog.Entry,
        exe: URL,
        bottle: Bottle,
        prefix: URL,
        progress: (@Sendable (InstallPhase, Double) -> Void)?
    ) async throws {
        guard let spec = entry.bootstrap else { return }
        let readyFile = WindowsPath.toUnix(spec.readyWindowsPath, prefix: prefix)
        // Already bootstrapped (e.g. re-install over an existing prefix).
        if Self.fileSize(of: readyFile) >= spec.readyMinBytes {
            return
        }

        // wait:false — `wine start /unix` returns while Steam keeps running.
        _ = try? await launcher.run(exe: exe, arguments: entry.launchArguments, in: bottle, wait: false)

        let deadline = Date().addingTimeInterval(TimeInterval(spec.timeoutSeconds))
        var ready = false
        var relaunches = 0
        var lastActivity = Self.bootstrapActivity(around: readyFile)
        var lastActivityAt = Date()
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let size = Self.fileSize(of: readyFile)
            progress?(.configuring, min(0.99, Double(size) / Double(spec.readyMinBytes)))
            if size >= spec.readyMinBytes {
                ready = true
                break
            }
            // Stall detection: if the client's install tree shows no writes at
            // all for a while, the client died or its self-update hung (the
            // clean-machine "Failed to load steamui.dll" case). Kill leftovers
            // and relaunch — the bootstrap download resumes where it stopped.
            let activity = Self.bootstrapActivity(around: readyFile)
            if activity != lastActivity {
                lastActivity = activity
                lastActivityAt = Date()
            } else if Date().timeIntervalSince(lastActivityAt) >= bootstrapStallSeconds,
                      relaunches < Self.maxBootstrapRelaunches {
                try? await launcher.stopAll(in: bottle)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                _ = try? await launcher.run(exe: exe, arguments: entry.launchArguments, in: bottle, wait: false)
                relaunches += 1
                lastActivityAt = Date()
            }
        }

        try? await launcher.stopAll(in: bottle)
        // Let wineserver release the prefix before we mutate files in it.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        guard ready else { throw InstallError.bootstrapTimedOut(name: entry.name) }
    }

    private static let maxBootstrapRelaunches = 3

    /// Cheap fingerprint of download progress: file count + total bytes of the
    /// client's install directory (top level and its `package/` download area).
    /// Any write the bootstrapper makes changes it.
    private static func bootstrapActivity(around readyFile: URL) -> (count: Int, bytes: Int) {
        let fm = FileManager.default
        let installDir = readyFile.deletingLastPathComponent()
        var count = 0
        var bytes = 0
        for dir in [installDir, installDir.appendingPathComponent("package")] {
            guard let children = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey], options: []
            ) else { continue }
            count += children.count
            bytes += children.reduce(0) { $0 + (Self.fileSize(of: $1)) }
        }
        return (count, bytes)
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}
