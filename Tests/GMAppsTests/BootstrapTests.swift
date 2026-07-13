import Foundation
import GMBottles
import GMLaunch
import GMModel
import GMRuntime
import GMSystem
import GMTestSupport
import Testing
@testable import GMApps

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-bootstrap-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct Env {
    let root: URL
    let runtimeStore: RuntimeStore
    let bottleStore: BottleStore
    let bottle: Bottle
    let runner: FakeRunner

    func launcher() -> WineLauncher {
        WineLauncher(
            runtimeStore: runtimeStore,
            bottleStore: bottleStore,
            runner: runner,
            logsRoot: root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
    }
}

private func makeEnv() async throws -> Env {
    let root = try tempDir()
    let runtimeStore = RuntimeStore(root: root)
    try await runtimeStore.save(RuntimeDescriptor(
        id: "rt",
        displayVersion: "GPTK test",
        wineBinaryRelativePath: "gptk/wine/bin/wine64",
        gptk: .installed(version: "3.0")
    ))
    try await runtimeStore.save(RuntimeDescriptor(
        id: "sikarugir-10.0-6-dxmt-0.80",
        displayVersion: "Sikarugir test",
        wineBinaryRelativePath: "wswine.bundle/bin/wine",
        gptk: .none,
        dxmt: .installed(version: "0.80")
    ))
    let bottleStore = BottleStore(root: root)
    let bottle = try await bottleStore.create(name: "Bottle", runtimeID: "rt")
    return Env(root: root, runtimeStore: runtimeStore, bottleStore: bottleStore, bottle: bottle, runner: FakeRunner())
}

private func steamDirectory(in prefix: URL) -> URL {
    prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
}

/// Writes steam.exe plus a steamui.dll large enough to satisfy the installer's
/// bootstrap-ready poll.
private func writeBootstrappedSteam(in prefix: URL, exe: Data = Data("MZ".utf8)) throws {
    let steamDir = steamDirectory(in: prefix)
    try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
    try exe.write(to: steamDir.appendingPathComponent("steam.exe"))
    try Data(count: 10_000_001).write(to: steamDir.appendingPathComponent("steamui.dll"))
}

/// First-run bootstrap behavior: readiness polling, stall relaunch, offline
/// fail-fast. Split from AppsTests to keep files under the lint size cap.
@Suite("AppInstaller bootstrap")
struct AppInstallerBootstrapTests {
    /// The ready file appears only AFTER polling starts (the real first-install
    /// timeline). Guards against stat caching: URL.resourceValues caches on the
    /// URL object, which made the poll read "missing" forever and hang fresh
    /// installs at "Configuring…" even after steamui.dll had fully downloaded.
    @Test func bootstrapSeesReadyFileThatAppearsWhilePolling() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let steamDir = steamDirectory(in: prefix)
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))

        let entry = try InstallerCatalog.Entry(
            id: "steam",
            name: "Steam",
            downloadURL: #require(URL(string: "https://example/SteamSetup.exe")),
            installerFileName: "SteamSetup.exe",
            silentArguments: ["/S"],
            installedWindowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            launchArguments: [],
            bootstrap: .init(
                readyWindowsPath: "C:\\Program Files (x86)\\Steam\\steamui.dll",
                readyMinBytes: 10_000_000,
                timeoutSeconds: 60
            ),
            runRuntimeID: "sikarugir-10.0-6-dxmt-0.80"
        )
        // Deliver steamui.dll a few seconds into the poll, like a real download.
        let dllPath = steamDir.appendingPathComponent("steamui.dll")
        Task.detached {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            try? Data(count: 10_000_001).write(to: dllPath)
        }
        let started = Date()
        _ = try await installer.install(entry, into: env.bottle, progress: nil)
        // Completed shortly after the file landed — not at the 60 s timeout.
        #expect(Date().timeIntervalSince(started) < 30)
        let saved = try #require(await env.bottleStore.list().first)
        #expect(saved.runtimeID == "sikarugir-10.0-6-dxmt-0.80")
    }

    /// A previous failed install can leave the client running in the bottle;
    /// the installer then can't replace locked files and dies with exit code 2.
    /// Install must clear the bottle (wineserver -k) BEFORE running the
    /// installer.
    @Test func installStopsBottleProcessesBeforeRunningInstaller() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let steam = try #require(InstallerCatalog.bundled().entries.first { $0.id == "steam" })
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        try writeBootstrappedSteam(in: prefix)
        _ = try await installer.install(steam, into: env.bottle, progress: nil)

        let kill = env.runner.invocations.firstIndex {
            $0.executable.hasSuffix("wineserver") && $0.arguments == ["-k"]
        }
        let setup = env.runner.invocations.firstIndex {
            $0.arguments.contains { $0.hasSuffix("SteamSetup.exe") }
        }
        let killIndex = try #require(kill)
        let setupIndex = try #require(setup)
        #expect(killIndex < setupIndex)
    }

    /// The bootstrapper's log reports each failed download ("Steam needs to be
    /// online to update" when its CDN is unreachable). Once THIS bootstrap has
    /// produced more failures than the relaunch budget, the install must fail
    /// fast with a network error — not sit out the 15-minute timeout.
    @Test func bootstrapFailsFastWhenLogReportsOffline() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let steamDir = steamDirectory(in: prefix)
        let logsDir = steamDir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        // The launched client records four failed attempts shortly after this
        // bootstrap starts — more NEW failures than the relaunch budget. The
        // write lands at ~4 s: after the bootstrap's baseline capture (which
        // follows the 2 s pre-install settle), before the first 3 s poll.
        let failedAttempt = "[2026-07-12] Error: Steam needs to be online to update. Please confirm.\n"
        let logFile = logsDir.appendingPathComponent("bootstrap_log.txt")
        Task.detached {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            try? String(repeating: failedAttempt, count: 4)
                .write(to: logFile, atomically: true, encoding: .utf8)
        }

        let entry = try InstallerCatalog.Entry(
            id: "steam",
            name: "Steam",
            downloadURL: #require(URL(string: "https://example/SteamSetup.exe")),
            installerFileName: "SteamSetup.exe",
            silentArguments: ["/S"],
            installedWindowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            launchArguments: [],
            bootstrap: .init(
                readyWindowsPath: "C:\\Program Files (x86)\\Steam\\steamui.dll",
                readyMinBytes: 10_000_000,
                timeoutSeconds: 600,
                failureLogWindowsPath: "C:\\Program Files (x86)\\Steam\\logs\\bootstrap_log.txt",
                failureLogPatterns: ["Steam needs to be online to update"]
            )
        )
        let started = Date()
        await #expect(throws: InstallError.bootstrapOffline(name: "Steam")) {
            _ = try await installer.install(entry, into: env.bottle, progress: nil)
        }
        // Failed on an early poll round, nowhere near the 600 s timeout.
        #expect(Date().timeIntervalSince(started) < 30)
    }

    /// bootstrap_log.txt is append-only across attempts: failures recorded by
    /// a PREVIOUS install run must not poison this one. A retry on a healthy
    /// network has to succeed even with old failure lines on record — only
    /// lines added after this bootstrap starts may count.
    @Test func bootstrapIgnoresFailuresFromPreviousAttempts() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let steamDir = steamDirectory(in: prefix)
        let logsDir = steamDir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        // A previous attempt failed four times — over the relaunch budget.
        let failedAttempt = "[2026-07-12] Error: Steam needs to be online to update. Please confirm.\n"
        try String(repeating: failedAttempt, count: 4)
            .write(to: logsDir.appendingPathComponent("bootstrap_log.txt"), atomically: true, encoding: .utf8)

        let entry = try InstallerCatalog.Entry(
            id: "steam",
            name: "Steam",
            downloadURL: #require(URL(string: "https://example/SteamSetup.exe")),
            installerFileName: "SteamSetup.exe",
            silentArguments: ["/S"],
            installedWindowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            launchArguments: [],
            bootstrap: .init(
                readyWindowsPath: "C:\\Program Files (x86)\\Steam\\steamui.dll",
                readyMinBytes: 10_000_000,
                timeoutSeconds: 60,
                failureLogWindowsPath: "C:\\Program Files (x86)\\Steam\\logs\\bootstrap_log.txt",
                failureLogPatterns: ["Steam needs to be online to update"]
            )
        )
        // This time the network is fine: the client download completes — but
        // only after the poll has already run its failure check at least once
        // (pre-install settle 2 s + first poll 3 s ≈ 5 s), so the stale lines
        // are actually seen and must be ignored.
        let dllPath = steamDir.appendingPathComponent("steamui.dll")
        Task.detached {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            try? Data(count: 10_000_001).write(to: dllPath)
        }
        _ = try await installer.install(entry, into: env.bottle, progress: nil)

        // The stale failures caused neither an offline abort nor pointless
        // relaunch churn: steam.exe was started exactly once.
        let steamStarts = env.runner.invocations.filter { invocation in
            invocation.arguments.contains { $0.hasSuffix("steam.exe") }
                && invocation.arguments.contains("start")
        }
        #expect(steamStarts.count == 1)
    }

    /// A clean-machine failure mode: Steam's first self-update dies (the user
    /// sees "Failed to load steamui.dll" and the client exits). The bootstrap
    /// poll must notice the stall — no download activity at all — and relaunch
    /// steam.exe instead of waiting out the full timeout doing nothing.
    @Test func bootstrapRelaunchesSteamWhenDownloadStalls() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore,
            bootstrapStallSeconds: 0.5
        )
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let steamDir = steamDirectory(in: prefix)
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))

        let entry = try InstallerCatalog.Entry(
            id: "steam",
            name: "Steam",
            downloadURL: #require(URL(string: "https://example/SteamSetup.exe")),
            installerFileName: "SteamSetup.exe",
            silentArguments: ["/S"],
            installedWindowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            launchArguments: ["-allosarches", "-noverifyfiles"],
            bootstrap: .init(
                readyWindowsPath: "C:\\Program Files (x86)\\Steam\\steamui.dll",
                readyMinBytes: 10_000_000,
                timeoutSeconds: 8,
                launchArguments: ["-allosarches"]
            )
        )
        await #expect(throws: InstallError.bootstrapTimedOut(name: "Steam")) {
            _ = try await installer.install(entry, into: env.bottle, progress: nil)
        }
        // steam.exe was started more than once (initial + at least one stall
        // relaunch), with a wineserver kill in between to clear the dead client.
        let steamStarts = env.runner.invocations.filter { invocation in
            invocation.arguments.contains { $0.hasSuffix("steam.exe") }
                && invocation.arguments.contains("start")
        }
        #expect(steamStarts.count >= 2)
        // Every bootstrap start uses the bootstrap-specific arguments —
        // verification must run on a fresh install or nothing downloads.
        #expect(steamStarts.allSatisfy { $0.arguments.contains("-allosarches") })
        #expect(steamStarts.allSatisfy { !$0.arguments.contains("-noverifyfiles") })
        let kills = env.runner.invocations.count {
            $0.executable.hasSuffix("wineserver") && $0.arguments == ["-k"]
        }
        #expect(kills >= 2) // stall relaunch + final cleanup
    }

    @Test func bootstrapTimesOutWhenClientNeverDownloads() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        // steam.exe present so the completion check passes, but steamui.dll never
        // appears (no real download in tests), so bootstrap must time out.
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let steamDir = steamDirectory(in: prefix)
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))

        let entry = try InstallerCatalog.Entry(
            id: "steam",
            name: "Steam",
            downloadURL: #require(URL(string: "https://example/SteamSetup.exe")),
            installerFileName: "SteamSetup.exe",
            silentArguments: ["/S"],
            installedWindowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            launchArguments: [],
            bootstrap: .init(
                readyWindowsPath: "C:\\Program Files (x86)\\Steam\\steamui.dll",
                readyMinBytes: 10_000_000,
                timeoutSeconds: 1
            ),
            runRuntimeID: "wine-staging-11.10"
        )
        await #expect(throws: InstallError.bootstrapTimedOut(name: "Steam")) {
            _ = try await installer.install(entry, into: env.bottle, progress: nil)
        }
        // A timed-out install must not switch the runtime or register a program,
        // so a retry starts from a clean, still-GPTK bottle.
        let saved = try #require(await env.bottleStore.list().first)
        #expect(saved.programs.isEmpty)
        #expect(saved.runtimeID == "rt")
    }
}
