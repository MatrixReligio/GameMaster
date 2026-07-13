import Foundation
import GMBottles
import GMModel
import GMRuntime
import GMSystem
import GMTestSupport
import Synchronization
import Testing
@testable import GMApps

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-appstate-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a runtime tarball fixture and a manifest entry whose sha matches.
private func makeRuntimeFixtureEntry(in dir: URL) async throws -> (URL, RuntimeManifest.Entry) {
    let tree = dir.appendingPathComponent("tree/Game Porting Toolkit.app/Contents/Resources/wine/bin")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho wine\n".utf8).write(to: tree.appendingPathComponent("wine64"))
    let archive = dir.appendingPathComponent("runtime.tar.gz")
    _ = try await SubprocessRunner().run(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-czf", archive.path, "-C", dir.appendingPathComponent("tree").path, "Game Porting Toolkit.app"],
        environment: nil,
        currentDirectory: nil,
        outputLine: nil
    )
    let entry = try RuntimeManifest.Entry(
        id: "gptk-test",
        displayVersion: "GPTK test",
        url: #require(URL(string: "https://example.com/runtime.tar.gz")),
        sha256: SHA256.hexDigest(of: archive),
        wineBinaryRelativePath: "Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
        bundledGPTKVersion: "3.0"
    )
    return (archive, entry)
}

/// Builds a Wine-Staging-shaped runtime tarball (single `wine` binary, new
/// WoW64) and a manifest entry whose sha matches — the runtime Steam runs under.
private func makeWineStagingFixtureEntry(in dir: URL) async throws -> (URL, RuntimeManifest.Entry) {
    let tree = dir.appendingPathComponent("wtree/Wine Staging.app/Contents/Resources/wine/bin")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho wine\n".utf8).write(to: tree.appendingPathComponent("wine"))
    let archive = dir.appendingPathComponent("wine.tar.gz")
    _ = try await SubprocessRunner().run(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-czf", archive.path, "-C", dir.appendingPathComponent("wtree").path, "Wine Staging.app"],
        environment: nil,
        currentDirectory: nil,
        outputLine: nil
    )
    let entry = try RuntimeManifest.Entry(
        id: "sikarugir-10.0-6-dxmt-0.80",
        displayVersion: "Sikarugir test",
        url: #require(URL(string: "https://example.com/wine.tar.gz")),
        sha256: SHA256.hexDigest(of: archive),
        wineBinaryRelativePath: "Wine Staging.app/Contents/Resources/wine/bin/wine",
        bundledGPTKVersion: nil,
        bundledDXMTVersion: "0.80"
    )
    return (archive, entry)
}

/// Serves different fixtures per download URL, so one install flow can fetch both
/// the GPTK runtime and the Steam run runtime.
private struct MultiDownloader: Downloading {
    let byLastComponent: [String: URL]

    func download(from url: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        guard let fixture = byLastComponent[url.lastPathComponent] else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fixture, to: destination)
        progress?(1.0)
    }
}

@MainActor
private func makeState(dir: URL, fixture: URL, entry: RuntimeManifest.Entry, runner: FakeRunner) -> AppState {
    AppState(
        root: dir.appendingPathComponent("approot"),
        runner: runner,
        downloader: FakeDownloader(fixture: fixture),
        mounter: FakeMounter(mountPoint: dir),
        manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
        systemToolRunner: SubprocessRunner()
    )
}

@Suite("AppState")
@MainActor
struct AppStateTests {
    /// Stop must be graceful: Steam gets its own `-shutdown` (saves state,
    /// syncs the cloud) routed through the running instance; anything else
    /// gets WM_CLOSE via taskkill. Neither is the wineserver hard kill.
    @Test func stopProgramPrefersCatalogShutdownThenTaskkill() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = FakeRunner()
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: runner)
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        let steam = Program(
            name: "Steam",
            windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe"
        )
        await state.stopProgram(steam, in: bottle)
        let shutdown = try #require(runner.invocations.last)
        #expect(shutdown.arguments.contains("-shutdown"))
        #expect(shutdown.arguments.contains { $0.hasSuffix("steam.exe") })
        #expect(!shutdown.arguments.contains("/wait"))

        let generic = Program(name: "G", windowsPath: "C:\\games\\g.exe")
        await state.stopProgram(generic, in: bottle)
        let taskkill = try #require(runner.invocations.last)
        #expect(taskkill.arguments == ["taskkill", "/IM", "g.exe"])
    }

    @Test func onboardingNeededUntilRuntimeInstalled() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())

        await state.refresh()
        #expect(state.needsOnboarding)
        if case .missing = state.runtimeStatus {} else {
            Issue.record("expected .missing, got \(state.runtimeStatus)")
        }

        await state.installDefaultRuntime()
        #expect(state.lastErrorMessage == nil)
        #expect(!state.needsOnboarding)
        if case let .ready(gptk) = state.runtimeStatus {
            #expect(gptk == .installed(version: "3.0"))
        } else {
            Issue.record("expected .ready, got \(state.runtimeStatus)")
        }
    }

    @Test func createBottleInitializesPrefixAndAppearsInList() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = FakeRunner()
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: runner)
        await state.installDefaultRuntime()

        await state.createBottle(name: "游戏")
        #expect(state.lastErrorMessage == nil)
        #expect(state.bottles.count == 1)
        #expect(state.bottles.first?.name == "游戏")
        // wineboot --init + regedit ran against the new prefix.
        let arguments = runner.invocations.map(\.arguments)
        #expect(arguments.contains { $0 == ["wineboot", "--init"] })
        #expect(arguments.contains { $0.first == "regedit" })
    }

    @Test func installSteamRegistersPinnedProgram() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        // Simulate the installer producing steam.exe plus an already-downloaded
        // steamui.dll, so the installer's bootstrap poll finds the client and
        // doesn't wait out its (minutes-long) real-download timeout.
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
        let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        try Data(count: 10_000_001).write(to: steamDir.appendingPathComponent("steamui.dll"))

        await state.installCatalogApp(id: "steam", into: bottle)
        #expect(state.lastErrorMessage == nil)
        let updated = try #require(state.bottles.first)
        #expect(updated.programs.count == 1)
        #expect(updated.programs.first?.name == "Steam")
        #expect(updated.programs.first?.pinned == true)
    }

    @Test func installSteamFetchesRunRuntimeAndSwitchesBottle() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (gptkFixture, gptkEntry) = try await makeRuntimeFixtureEntry(in: dir)
        let (wineFixture, wineEntry) = try await makeWineStagingFixtureEntry(in: dir)
        let downloader = MultiDownloader(byLastComponent: [
            "runtime.tar.gz": gptkFixture, // GPTK (default runtime)
            "wine.tar.gz": wineFixture, // Steam's run runtime
            "SteamSetup.exe": gptkFixture // content irrelevant; FakeRunner no-ops the install
        ])
        let manifest = RuntimeManifest(defaultRuntimeID: gptkEntry.id, entries: [gptkEntry, wineEntry])
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: downloader,
            mounter: FakeMounter(mountPoint: dir),
            manifest: manifest,
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        // Steam bootstrapped (steamui.dll present), so the installer skips the
        // real download and proceeds to switch the bottle to the run runtime.
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
        let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        try Data(count: 10_000_001).write(to: steamDir.appendingPathComponent("steamui.dll"))

        await state.installCatalogApp(id: "steam", into: bottle)
        #expect(state.lastErrorMessage == nil)

        // The run runtime was fetched (its metadata landed in the store), and the
        // bottle now points at it.
        let runtimeMeta = dir
            .appendingPathComponent("approot/runtimes/sikarugir-10.0-6-dxmt-0.80/runtime.json")
        #expect(FileManager.default.fileExists(atPath: runtimeMeta.path))
        let updated = try #require(state.bottles.first)
        #expect(updated.runtimeID == "sikarugir-10.0-6-dxmt-0.80")
        #expect(updated.programs.contains { $0.name == "Steam" })
    }

    @Test func launchMigratesOldGptkSteamBottleToRunRuntime() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (gptkFixture, gptkEntry) = try await makeRuntimeFixtureEntry(in: dir)
        let (wineFixture, wineEntry) = try await makeWineStagingFixtureEntry(in: dir)
        let downloader = MultiDownloader(byLastComponent: [
            "runtime.tar.gz": gptkFixture,
            "wine.tar.gz": wineFixture
        ])
        let manifest = RuntimeManifest(defaultRuntimeID: gptkEntry.id, entries: [gptkEntry, wineEntry])
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: downloader,
            mounter: FakeMounter(mountPoint: dir),
            manifest: manifest,
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        #expect(bottle.runtimeID == gptkEntry.id) // old bottle: still on GPTK

        // Simulate a pre-fix Steam install: bootstrapped client (steamui.dll),
        // genuine web helper, NO wrapper — the state that loops under GPTK.
        let steamDir = dir
            .appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
            .appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let cef = steamDir.appendingPathComponent("bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        try Data(count: 10_000_001).write(to: steamDir.appendingPathComponent("steamui.dll"))
        try Data(count: 2_000_000).write(to: cef.appendingPathComponent("steamwebhelper.exe"))

        let steam = Program(
            name: "Steam",
            windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            pinned: true
        )
        await state.launch(program: steam, in: bottle)
        #expect(state.lastErrorMessage == nil)

        // Migrated: run runtime installed, bottle switched, wrapper installed.
        let runtimeMeta = dir
            .appendingPathComponent("approot/runtimes/sikarugir-10.0-6-dxmt-0.80/runtime.json")
        #expect(FileManager.default.fileExists(atPath: runtimeMeta.path))
        let migrated = try #require(state.bottles.first { $0.id == bottle.id })
        #expect(migrated.runtimeID == "sikarugir-10.0-6-dxmt-0.80")
        let helperSize = try FileManager.default
            .attributesOfItem(atPath: cef.appendingPathComponent("steamwebhelper.exe").path)[.size] as? Int
        #expect((helperSize ?? .max) < 1_000_000) // now the small wrapper, not the 2 MB genuine
        #expect(FileManager.default.fileExists(atPath: cef.appendingPathComponent("steamwebhelper_real.exe").path))
        // No longer migrating after completion.
        #expect(state.migratingProgramID == nil)
    }

    /// Deleting a bottle while an install is writing into it would leave a
    /// half-installed ghost; the delete must be refused until the install ends.
    @Test func deleteBottleRefusedWhileInstalling() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)

        /// Blocks the Steam installer download until released; everything
        /// else (the runtime tarball) downloads immediately.
        final class GatedDownloader: Downloading, @unchecked Sendable {
            let fixture: URL
            private let released = Mutex<Bool>(false)
            init(fixture: URL) { self.fixture = fixture }
            func release() { released.withLock { $0 = true } }

            func download(
                from url: URL,
                to destination: URL,
                progress: (@Sendable (Double) -> Void)?
            ) async throws {
                if url.lastPathComponent == "SteamSetup.exe" {
                    while !released.withLock({ $0 }) {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: fixture, to: destination)
                progress?(1.0)
            }
        }

        let downloader = GatedDownloader(fixture: fixture)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: downloader,
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
        let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        try Data(count: 10_000_001).write(to: steamDir.appendingPathComponent("steamui.dll"))

        let install = Task { await state.installCatalogApp(id: "steam", into: bottle) }
        while !state.busyBottleIDs.contains(bottle.id) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await state.deleteBottle(bottle)
        #expect(state.lastErrorMessage != nil)
        #expect(state.bottles.contains { $0.id == bottle.id })

        downloader.release()
        await install.value
        #expect(!state.busyBottleIDs.contains(bottle.id))

        // After the install finishes, deleting works again.
        state.lastErrorMessage = nil
        let finished = try #require(state.bottles.first { $0.id == bottle.id })
        await state.deleteBottle(finished)
        #expect(!state.bottles.contains { $0.id == bottle.id })
    }

    /// A corrupt bottle.json must not make the bottle vanish silently — the
    /// user is told, and the file stays on disk for recovery.
    @Test func refreshReportsCorruptBottleMetadata() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())
        await state.installDefaultRuntime()
        await state.createBottle(name: "OK")

        let corrupt = dir.appendingPathComponent("approot/bottles/corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("bottle.json"))

        state.lastErrorMessage = nil
        await state.refresh()
        #expect(state.bottles.count == 1)
        #expect(state.lastErrorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("bottle.json").path))
    }

    /// The settings sheet owns name + settings only. Saving them from a stale
    /// draft must not clobber programs/runtime added while the sheet was open.
    @Test func updateBottleSettingsDoesNotClobberConcurrentChanges() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let draft = try #require(state.bottles.first) // sheet opens on this

        // While the sheet is open, an install registers a program.
        let store = BottleStore(root: dir.appendingPathComponent("approot"))
        let program = Program(name: "Steam", windowsPath: "C:\\steam.exe")
        _ = try await store.update(id: draft.id) { $0.programs.append(program) }

        var settings = draft.settings
        settings.metalHUD = true
        await state.updateBottle(id: draft.id, name: "Renamed", settings: settings)

        let final = try #require(state.bottles.first)
        #expect(final.name == "Renamed")
        #expect(final.settings.metalHUD)
        #expect(final.programs == [program]) // survived the sheet save
    }

    /// Retina lives in the Wine registry, written at bottle creation. Toggling
    /// it later must re-apply the registry tweak — saving JSON alone leaves
    /// the running environment unchanged (the setting silently did nothing).
    @Test func updateBottleReappliesRetinaRegistryWhenChanged() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = FakeRunner()
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: runner)
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        #expect(bottle.settings.retinaMode) // default on

        let regeditRuns = { runner.invocations.count { $0.arguments.first == "regedit" } }
        let before = regeditRuns()

        // Toggle retina → the registry tweak must run again.
        var settings = bottle.settings
        settings.retinaMode = false
        await state.updateBottle(id: bottle.id, name: bottle.name, settings: settings)
        #expect(state.lastErrorMessage == nil)
        #expect(regeditRuns() == before + 1)

        // Saving without touching retina must NOT re-run regedit.
        var unchanged = try #require(state.bottles.first).settings
        unchanged.metalHUD = true
        await state.updateBottle(id: bottle.id, name: "Renamed", settings: unchanged)
        #expect(regeditRuns() == before + 1)
    }

    @Test func errorsSurfaceAsMessages() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, badEntry) = try await makeRuntimeFixtureEntry(in: dir)
        var entry = badEntry
        entry.sha256 = String(repeating: "0", count: 64)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())

        await state.installDefaultRuntime()
        #expect(state.lastErrorMessage != nil)
        if case .missing = state.runtimeStatus {} else {
            Issue.record("failed install must return to .missing")
        }
    }

    /// A program that dies right after launch (missing DLL, bad path, crashed
    /// loader) must surface an error — not just flick the card back to idle
    /// with no explanation.
    @Test func launchReportsQuickNonzeroExit() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = FakeRunner()
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: runner)
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        runner.setExitCode(1)
        state.lastErrorMessage = nil
        await state.launch(program: Program(name: "P", windowsPath: "C:\\p.exe"), in: bottle)
        #expect(state.lastErrorMessage != nil)
    }

    /// A NONZERO exit after a long session is normal for games (many return
    /// junk codes on quit) and must NOT produce an error.
    @Test func launchIgnoresNonzeroExitAfterLongRun() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        // Every wine call takes 300 ms — longer than the injected 0.1 s window.
        let runner = FakeRunner(delayNanoseconds: 300_000_000)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: runner,
            downloader: FakeDownloader(fixture: fixture),
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner(),
            launchFailureWindowSeconds: 0.1
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        runner.setExitCode(3)
        state.lastErrorMessage = nil
        await state.launch(program: Program(name: "P", windowsPath: "C:\\p.exe"), in: bottle)
        #expect(state.lastErrorMessage == nil)
    }

    /// Run Once launches fire-and-forget through wine's `start` helper — a
    /// nonzero helper exit means the program never launched. Tell the user.
    @Test func runExeReportsHelperFailure() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = FakeRunner()
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: runner)
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        runner.setExitCode(2)
        state.lastErrorMessage = nil
        await state.runExe(dir.appendingPathComponent("game.exe"), in: bottle)
        #expect(state.lastErrorMessage != nil)
    }

    @Test func launchAndStopDelegateToWine() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = FakeRunner()
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: runner)
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        let program = Program(name: "P", windowsPath: "C:\\p.exe")
        await state.launch(program: program, in: bottle)
        #expect(runner.invocations.contains { $0.arguments.first == "start" })

        await state.stopAll(in: bottle)
        #expect(runner.invocations.contains { $0.executable.hasSuffix("wineserver") })
    }
}
