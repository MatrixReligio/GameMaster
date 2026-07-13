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
    case bootstrapOffline(name: String)

    public var errorDescription: String? {
        switch self {
        case let .installerFailed(name, exitCode):
            String(localized: "The \(name) installer failed (exit code \(exitCode)). Please try again.")
        case let .programNotFound(name, _):
            String(localized: "The \(name) installer finished but the program wasn't found. Please try again.")
        case let .bootstrapTimedOut(name):
            String(localized: "\(name) did not finish downloading in time. Check your connection and try again.")
        case let .bootstrapOffline(name):
            String(
                localized: "\(name) could not reach its download servers. Check your network or proxy, then try again."
            )
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
        // A previous failed attempt can leave the client running in the bottle
        // (quitting the app doesn't always kill wine children). The installer
        // then can't replace locked files and aborts with exit code 2 — so
        // clear the bottle first; on a quiet bottle this is a no-op.
        try? await launcher.stopAll(in: bottle)
        try await Task.sleep(nanoseconds: 2_000_000_000)
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
        // Apply only THIS install's fields on the bottle's current state:
        // the install ran for minutes, and a whole-value save of the snapshot
        // taken at its start would drop every change made in between (rename,
        // settings). update() also throws instead of resurrecting a bottle
        // that was deleted mid-install.
        let runRuntimeID = entry.runRuntimeID
        let runTuning = entry.runTuning
        let installedWindowsPath = entry.installedWindowsPath
        try await bottleStore.update(id: bottle.id) { current in
            // Switch the bottle to the run runtime (Steam bootstraps under GPTK
            // but runs under a newer Wine whose CEF handshake completes).
            if let runRuntimeID {
                current.runtimeID = runRuntimeID
            }
            Self.applyRunTuning(runTuning, to: &current)
            current.programs.removeAll { $0.windowsPath == installedWindowsPath }
            current.programs.append(program)
        }

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
        // Field-level update on current state — see install() for why.
        let runRuntimeID = entry.runRuntimeID
        let runTuning = entry.runTuning
        let updated = try await bottleStore.update(id: bottle.id) { current in
            if let runRuntimeID {
                current.runtimeID = runRuntimeID
            }
            Self.applyRunTuning(runTuning, to: &current)
        }
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

        // The failure log is append-only across attempts: failures recorded by
        // a previous install run must not poison this one. Take the count
        // BEFORE launching the client and only new lines count from here on.
        let failureLog = spec.failureLogWindowsPath.map { WindowsPath.toUnix($0, prefix: prefix) }
        let baselineFailures = Self.failureCount(in: failureLog, patterns: spec.failureLogPatterns)

        // wait:false — `wine start /unix` returns while Steam keeps running.
        let bootstrapArguments = spec.launchArguments ?? entry.launchArguments
        _ = try? await launcher.run(exe: exe, arguments: bootstrapArguments, in: bottle, wait: false)
        let deadline = Date().addingTimeInterval(TimeInterval(spec.timeoutSeconds))
        var ready = false
        var offline = false
        var relaunches = 0
        var handledFailures = 0
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

            // Download-failure detection: the bootstrapper logs each failed
            // attempt (e.g. Steam's "Download failed" when its CDN is
            // unreachable). Retry immediately — CDN hiccups are transient —
            // and once the relaunch budget is spent, fail fast with a network
            // error instead of sitting out the full timeout. Only failures
            // NEW since this bootstrap started count (see baselineFailures).
            let failures = Self.failureCount(in: failureLog, patterns: spec.failureLogPatterns)
                - baselineFailures
            if failures > Self.maxBootstrapRelaunches {
                offline = true
                break
            }
            if failures > handledFailures {
                handledFailures = failures
                try? await launcher.stopAll(in: bottle)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                _ = try? await launcher.run(exe: exe, arguments: bootstrapArguments, in: bottle, wait: false)
                relaunches += 1
                lastActivityAt = Date()
                continue
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
                _ = try? await launcher.run(exe: exe, arguments: bootstrapArguments, in: bottle, wait: false)
                relaunches += 1
                lastActivityAt = Date()
            }
        }

        try? await launcher.stopAll(in: bottle)
        // Let wineserver release the prefix before we mutate files in it.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        if offline {
            throw InstallError.bootstrapOffline(name: entry.name)
        }
        guard ready else { throw InstallError.bootstrapTimedOut(name: entry.name) }
    }

    /// Counts failed download attempts recorded in the bootstrapper's log.
    /// The log is append-only across relaunches AND across install attempts,
    /// so callers must diff against a baseline taken at bootstrap start —
    /// the raw total includes failures from previous runs.
    private static func failureCount(in log: URL?, patterns: [String]?) -> Int {
        guard let log, let patterns, !patterns.isEmpty,
              let content = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
        return content.components(separatedBy: "\n").count { line in
            patterns.contains { line.contains($0) }
        }
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

    /// Stats the file fresh on every call. Deliberately NOT
    /// `URL.resourceValues`: NSURL caches resource values on the URL object,
    /// and the bootstrap poll reuses one URL — with caching it read "missing"
    /// forever while steamui.dll finished downloading, hanging fresh installs
    /// at "Configuring…" until the timeout.
    private static func fileSize(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }
}
