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
        .appendingPathComponent("gm-appstate-guard-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a runtime tarball fixture and a manifest entry whose sha matches.
/// (Copied from AppStateTests — the helpers are file-private by design.)
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

/// Wine-Staging-shaped runtime tarball for the DXMT run runtime.
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

/// Serves different fixtures per download URL.
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

/// Blocks the Steam installer download until released; everything
/// else (the runtime tarball) downloads immediately.
private final class GatedDownloader: Downloading, @unchecked Sendable {
    let fixture: URL
    private let released = Mutex<Bool>(false)
    init(fixture: URL) {
        self.fixture = fixture
    }

    func release() {
        released.withLock { $0 = true }
    }

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

/// The guard rails around bottle lifecycle: busy/active delete protection,
/// corrupt-metadata reporting, transactional settings saves, retina re-apply,
/// launch failure surfacing, and runtime capability queries. Split from
/// AppStateTests to keep files under the lint size cap.
@Suite("AppState guards")
@MainActor
struct AppStateGuardTests {
    /// Deleting a bottle while an install is writing into it would leave a
    /// half-installed ghost; the delete must be refused until the install ends.
    @Test func deleteBottleRefusedWhileInstalling() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)

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

    /// A corrupt runtime.json must not make the runtime vanish silently
    /// (which read as "missing" and triggered a re-download) — the user is
    /// told, and the file stays on disk for recovery.
    @Test func refreshReportsCorruptRuntimeMetadata() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())
        await state.installDefaultRuntime()

        let corrupt = dir.appendingPathComponent("approot/runtimes/broken")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("runtime.json"))

        state.lastErrorMessage = nil
        await state.refresh()
        #expect(state.lastErrorMessage != nil)
        // The healthy runtime is unaffected.
        if case .ready = state.runtimeStatus {} else {
            Issue.record("runtimeStatus should stay ready, got \(state.runtimeStatus)")
        }
        #expect(FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("runtime.json").path))
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

    /// Games survive GameMaster quitting. On relaunch the app must rediscover
    /// bottles whose wineserver is still alive — showing them as running and
    /// refusing deletion — instead of treating them as idle.
    @Test func refreshDetectsExternallyRunningBottleAndBlocksDelete() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)

        final class FakeProbe: PrefixActivityProbing, @unchecked Sendable {
            private let active = Mutex<Set<String>>([])
            func setActive(_ prefix: URL, _ value: Bool) {
                active.withLock {
                    if value {
                        $0.insert(prefix.path)
                    } else {
                        $0.remove(prefix.path)
                    }
                }
            }

            func isActive(prefix: URL) -> Bool {
                active.withLock { $0.contains(prefix.path) }
            }
        }

        let probe = FakeProbe()
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: FakeDownloader(fixture: fixture),
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner(),
            activityProbe: probe
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        #expect(!state.activeBottleIDs.contains(bottle.id))

        // "App relaunch": the bottle's wineserver is alive out there.
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
        probe.setActive(prefix, true)
        await state.refresh()
        #expect(state.activeBottleIDs.contains(bottle.id))

        state.lastErrorMessage = nil
        await state.deleteBottle(bottle)
        #expect(state.lastErrorMessage != nil)
        #expect(state.bottles.contains { $0.id == bottle.id })

        // Programs stopped → delete works again.
        probe.setActive(prefix, false)
        await state.refresh()
        state.lastErrorMessage = nil
        await state.deleteBottle(bottle)
        #expect(!state.bottles.contains { $0.id == bottle.id })
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

    /// The settings sheet hides "DirectX translation: Off" for DXMT bottles —
    /// DXMT is installed INTO wine's builtins, so no setting can switch it
    /// off, and offering a dead toggle lies to the user.
    @Test func reportsWhetherBottleRuntimeCarriesDXMT() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (gptkFixture, gptkEntry) = try await makeRuntimeFixtureEntry(in: dir)
        let (wineFixture, wineEntry) = try await makeWineStagingFixtureEntry(in: dir)
        let downloader = MultiDownloader(byLastComponent: [
            "runtime.tar.gz": gptkFixture,
            "wine.tar.gz": wineFixture
        ])
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: downloader,
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: gptkEntry.id, entries: [gptkEntry, wineEntry]),
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let gptkBottle = try #require(state.bottles.first)
        #expect(await state.bottleUsesDXMTRuntime(gptkBottle) == false)

        var dxmtBottle = gptkBottle
        dxmtBottle.runtimeID = "sikarugir-10.0-6-dxmt-0.80"
        // Runtime not installed yet → conservatively not DXMT.
        #expect(await state.bottleUsesDXMTRuntime(dxmtBottle) == false)

        // Install the DXMT runtime, then the same bottle reports true.
        let installer = RuntimeInstaller(
            store: RuntimeStore(root: dir.appendingPathComponent("approot")),
            downloader: downloader,
            runner: SubprocessRunner()
        )
        _ = try await installer.install(entry: wineEntry, progress: nil)
        #expect(await state.bottleUsesDXMTRuntime(dxmtBottle) == true)
    }
}

/// wineboot takes seconds (more after a fresh runtime download, when Rosetta
/// first translates the wine binaries) — the UI needs a signal to show
/// progress instead of appearing dead.
@MainActor
@Suite("Bottle creation progress")
struct BottleCreationProgressTests {
    @Test func createBottleExposesInProgressState() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        // Every wine call (wineboot, regedit) takes 200 ms.
        let runner = FakeRunner(delayNanoseconds: 200_000_000)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: runner)
        await state.installDefaultRuntime()
        #expect(!state.creatingBottle)

        let creation = Task { await state.createBottle(name: "B") }
        while !state.creatingBottle {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(state.creatingBottle)
        await creation.value
        #expect(!state.creatingBottle)
        #expect(state.bottles.count == 1)
    }
}
