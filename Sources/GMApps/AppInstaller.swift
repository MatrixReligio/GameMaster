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
        _ = try await launcher.run(exe: installerFile, arguments: entry.silentArguments, in: bottle, wait: true)

        progress?(.configuring, 0)
        let prefix = await bottleStore.prefixDirectory(of: bottle)
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
