import Foundation
import GMBottles
import GMLaunch
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

    /// New bottles pick up hardware-tuned graphics defaults when a display
    /// profile is available: a HiDPI Mac renders at the logical resolution
    /// (Retina off) instead of the default on, so the GPU isn't spent on pixels
    /// the CPU-bound game can't feed. Existing bottles are never touched.
    @Test func createBottleAppliesHardwareRecommendation() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: FakeDownloader(fixture: fixture),
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner(),
            hardwareProfileProvider: { HardwareProfile(physicalWidth: 3840, logicalWidth: 1920, refreshHz: 60) }
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        #expect(bottle.settings.retinaMode == false)
    }

    /// With no detectable display (headless CI, tests) new bottles keep the
    /// plain defaults — nothing is guessed.
    @Test func createBottleKeepsDefaultsWithoutHardwareProfile() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        #expect(bottle.settings.retinaMode == true)
    }

    /// The settings sheet's "Recommend" button asks for settings tuned to this
    /// Mac; it returns a recommendation built from the bottle's current settings
    /// so unrelated fields are preserved, and callers apply it to their draft.
    @Test func recommendedSettingsUsesDisplayAndRuntime() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: FakeDownloader(fixture: fixture),
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner(),
            hardwareProfileProvider: { HardwareProfile(physicalWidth: 3840, logicalWidth: 1920, refreshHz: 60) }
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let recommended = await state.recommendedSettings(for: bottle)
        #expect(recommended?.retinaMode == false)
    }

    /// No display detectable → no recommendation (the button hides / does nothing).
    @Test func recommendedSettingsNilWithoutDisplay() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let recommended = await state.recommendedSettings(for: bottle)
        #expect(recommended == nil)
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
