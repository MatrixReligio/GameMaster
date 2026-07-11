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

    public var errorDescription: String? {
        switch self {
        case let .installerFailed(name, exitCode):
            String(localized: "The \(name) installer failed (exit code \(exitCode)). Please try again.")
        case let .programNotFound(name, _):
            String(localized: "The \(name) installer finished but the program wasn't found. Please try again.")
        }
    }
}

/// Orchestrates a one-click install: download the vendor installer, run it
/// silently in the bottle, drop config files, and register the program.
public struct AppInstaller: Sendable {
    private let downloader: any Downloading
    private let launcher: WineLauncher
    private let bottleStore: BottleStore

    public init(downloader: any Downloading, launcher: WineLauncher, bottleStore: BottleStore) {
        self.downloader = downloader
        self.launcher = launcher
        self.bottleStore = bottleStore
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
        var updated = bottle
        updated.programs.removeAll { $0.windowsPath == entry.installedWindowsPath }
        updated.programs.append(program)
        try await bottleStore.save(updated)

        progress?(.done, 1)
        return program
    }
}
