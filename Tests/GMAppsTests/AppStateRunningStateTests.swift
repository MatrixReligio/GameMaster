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
        .appendingPathComponent("gm-appstate-running-tests-\(UUID().uuidString)")
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

/// Scriptable wineserver-activity probe (per-prefix on/off switch).
private final class FakeProbe: PrefixActivityProbing, @unchecked Sendable {
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

@MainActor
private func makeProbedState(
    dir: URL,
    fixture: URL,
    entry: RuntimeManifest.Entry,
    probe: FakeProbe,
    stopProbeTimeoutSeconds: TimeInterval = 30
) -> AppState {
    AppState(
        root: dir.appendingPathComponent("approot"),
        runner: FakeRunner(),
        downloader: FakeDownloader(fixture: fixture),
        mounter: FakeMounter(mountPoint: dir),
        manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
        systemToolRunner: SubprocessRunner(),
        stopProbeTimeoutSeconds: stopProbeTimeoutSeconds,
        activityProbe: probe
    )
}

/// Running-state truth across app relaunches and stop requests: programs
/// keep running when GameMaster quits (by design), so the wineserver probe —
/// not just this session's bookkeeping — decides what shows as running.
/// Split from AppStateGuardTests to keep files under the lint size cap.
@Suite("AppState running state")
@MainActor
struct AppStateRunningStateTests {
    /// Games survive GameMaster quitting. On relaunch the app must rediscover
    /// bottles whose wineserver is still alive — showing them as running and
    /// refusing deletion — instead of treating them as idle.
    @Test func refreshDetectsExternallyRunningBottleAndBlocksDelete() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let probe = FakeProbe()
        let state = makeProbedState(dir: dir, fixture: fixture, entry: entry, probe: probe)
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

    /// After an app relaunch the per-program running IDs are gone, but the
    /// bottle's wineserver is still alive. The program must present as
    /// running — offering Play on a live bottle invites a second instance.
    @Test func programInActiveBottleReportsRunningAfterRestart() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let probe = FakeProbe()
        let state = makeProbedState(dir: dir, fixture: fixture, entry: entry, probe: probe)
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let program = Program(name: "Steam", windowsPath: "C:\\steam.exe")

        // "App relaunch": wineserver alive, runningIDs empty.
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
        probe.setActive(prefix, true)
        await state.refresh()
        #expect(state.runningIDs.isEmpty)
        #expect(state.isProgramRunning(program, in: bottle))

        probe.setActive(prefix, false)
        await state.refresh()
        #expect(!state.isProgramRunning(program, in: bottle))
    }

    /// Stopping must believe the probe, not the request: state clears only
    /// once the bottle's wineserver actually went quiet, and stays honest
    /// when the kill didn't take.
    @Test func stopPathsReprobeActivityInsteadOfAssumingSuccess() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let probe = FakeProbe()
        let state = makeProbedState(
            dir: dir, fixture: fixture, entry: entry, probe: probe, stopProbeTimeoutSeconds: 0.3
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
        let program = Program(name: "Steam", windowsPath: "C:\\steam.exe")

        // The kill didn't take (wineserver still alive) → still running.
        probe.setActive(prefix, true)
        await state.refresh()
        await state.stopAll(in: bottle)
        #expect(state.isProgramRunning(program, in: bottle))

        // Now it took → cleared without waiting for the next refresh.
        probe.setActive(prefix, false)
        await state.stopAll(in: bottle)
        #expect(!state.isProgramRunning(program, in: bottle))

        // The graceful per-program stop path reprobes the same way.
        probe.setActive(prefix, true)
        await state.refresh()
        #expect(state.isProgramRunning(program, in: bottle))
        probe.setActive(prefix, false)
        await state.stopProgram(program, in: bottle)
        #expect(!state.isProgramRunning(program, in: bottle))
    }

    /// "Add to Library and Run" must go through the running-state machine, not
    /// fire-and-forget: otherwise the freshly-added card shows Play while the
    /// program is already running, and a second click starts a duplicate. The
    /// added program must present as running while its launch is in flight.
    @Test func addAndRunLaunchesThroughRunningState() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = GatedLaunchRunner()
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: runner,
            downloader: FakeDownloader(fixture: fixture),
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        let exe = dir.appendingPathComponent("Game.exe")
        let launchTask = Task { await state.addProgramAndLaunch(exe: exe, in: bottle) }

        // The added program appears in the library and presents as running
        // while its (gated) launch is suspended at `start /wait`.
        var found: Program?
        for _ in 0 ..< 200 where found == nil {
            if let candidate = state.bottles.first?.programs.first(where: { $0.name == "Game" }),
               state.runningIDs.contains(candidate.id) {
                found = candidate
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let program = try #require(found)
        #expect(state.isProgramRunning(program, in: bottle))

        // Cleanup: release the gated launch so the task completes and clears.
        runner.release()
        await launchTask.value
        #expect(!state.runningIDs.contains(program.id))
    }

    /// A Stop that times out (program refuses to die — a save dialog, Steam
    /// updating) must not leave the card stuck showing "Closing…" with no
    /// button. After the timeout the program reverts to Running + Stop and its
    /// closing flag is cleared. No error is raised: the probe is whole-bottle,
    /// so a still-alive wineserver can also mean a slow-but-normal shutdown or
    /// a sibling program — surfacing "failed to stop" there would be a false
    /// alarm.
    @Test func stopTimeoutRevertsClosingToRunning() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let probe = FakeProbe()
        let runner = GatedLaunchRunner()
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: runner,
            downloader: FakeDownloader(fixture: fixture),
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner(),
            stopProbeTimeoutSeconds: 0.3,
            activityProbe: probe
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        var bottle = try #require(state.bottles.first)
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")

        // A program in the bottle's library, currently running: wineserver
        // alive and launch() suspended at the gated `start /wait`.
        let program = Program(name: "Game", windowsPath: "C:\\game.exe")
        let store = BottleStore(root: dir.appendingPathComponent("approot"))
        try await store.update(id: bottle.id) { $0.programs.append(program) }
        await state.refresh()
        bottle = try #require(state.bottles.first)
        probe.setActive(prefix, true)

        let launchTask = Task { await state.launch(program: program, in: bottle) }
        while !state.runningIDs.contains(program.id) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(state.closingIDs.isEmpty)

        // Stop: taskkill returns but the program won't die (probe stays active).
        state.lastErrorMessage = nil
        await state.stopProgram(program, in: bottle)

        #expect(state.isProgramRunning(program, in: bottle)) // still running
        #expect(!state.closingIDs.contains(program.id)) // not stuck "Closing…"
        #expect(state.lastErrorMessage == nil) // no false "failed to stop" alarm

        // Cleanup: let the (now unblocked) program exit so launch() returns.
        probe.setActive(prefix, false)
        runner.release()
        await launchTask.value
    }

    /// Importing GPTK replaces the shared runtime's libraries, so it must be
    /// refused while a program is running in any bottle — otherwise a live (or
    /// later-spawned) process could load a mix of old and new components. The
    /// import must not even start (no DMG mounted).
    @Test func refusesGPTKImportWhileAProgramIsRunning() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let probe = FakeProbe()
        let mounter = FakeMounter(mountPoint: dir)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: FakeDownloader(fixture: fixture),
            mounter: mounter,
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner(),
            activityProbe: probe
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
        probe.setActive(prefix, true) // a program is running

        state.lastErrorMessage = nil
        await state.importGPTK(dmg: dir.appendingPathComponent("eval.dmg"))
        #expect(state.lastErrorMessage != nil) // refused with a message
        #expect(mounter.mounted.isEmpty) // the import never started
    }

    /// The import lease closes the TOCTOU from the other side too: a launch that
    /// STARTS while a GPTK import holds the lease is refused, so it can't load a
    /// half-replaced runtime. (The import blocks on a gated mount to stay in
    /// flight while the launch is attempted.)
    @Test func refusesLaunchWhileRuntimeMaintenanceHeld() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: FakeDownloader(fixture: fixture),
            mounter: BlockingMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let program = Program(name: "G", windowsPath: "C:\\g.exe")

        // Import acquires the lease, then blocks on the mount — held in flight.
        let importTask = Task { await state.importGPTK(dmg: dir.appendingPathComponent("eval.dmg")) }
        while !state.runtimeMaintenanceInProgress {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        state.lastErrorMessage = nil
        await state.launch(program: program, in: bottle)
        #expect(state.lastErrorMessage != nil) // launch refused
        #expect(!state.runningIDs.contains(program.id)) // it never started

        importTask.cancel()
        _ = await importTask.value
    }

    /// And from this side: importing is refused while a launch is in flight
    /// (this-session `runningIDs`), not only when a wineserver is already alive.
    @Test func refusesGPTKImportWhileALaunchIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = GatedLaunchRunner()
        let mounter = FakeMounter(mountPoint: dir)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: runner,
            downloader: FakeDownloader(fixture: fixture),
            mounter: mounter,
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let program = Program(name: "G", windowsPath: "C:\\g.exe")

        let launchTask = Task { await state.launch(program: program, in: bottle) }
        while !state.runningIDs.contains(program.id) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        state.lastErrorMessage = nil
        await state.importGPTK(dmg: dir.appendingPathComponent("eval.dmg"))
        #expect(state.lastErrorMessage != nil)
        #expect(mounter.mounted.isEmpty) // import refused, never mounted

        runner.release()
        await launchTask.value
    }

    /// And a bottle CREATE in flight blocks the import too: the new bottle's
    /// wineboot loads from the shared runtime's wine/lib, yet the bottle isn't
    /// in `bottles` until its boot succeeds — so the import must gate on
    /// `creatingBottle`, not just running programs.
    @Test func refusesGPTKImportWhileACreateIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = GatedBootRunner()
        let mounter = FakeMounter(mountPoint: dir)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: runner,
            downloader: FakeDownloader(fixture: fixture),
            mounter: mounter,
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()

        // createBottle sets creatingBottle = true then blocks at wineboot.
        let createTask = Task { await state.createBottle(name: "B") }
        while !state.creatingBottle {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        state.lastErrorMessage = nil
        await state.importGPTK(dmg: dir.appendingPathComponent("eval.dmg"))
        #expect(state.lastErrorMessage != nil)
        #expect(mounter.mounted.isEmpty) // import refused, never mounted

        runner.release()
        await createTask.value
    }

    /// A "Run Once" (`runExe`) in flight blocks the import too: it launches a
    /// program via wine but sets no program id, so it marks a synthetic launch
    /// in `launchingIDs` for the import's check to see.
    @Test func refusesGPTKImportWhileARunExeIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = GatedLaunchRunner()
        let mounter = FakeMounter(mountPoint: dir)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: runner,
            downloader: FakeDownloader(fixture: fixture),
            mounter: mounter,
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)

        // Run Once, gated at wine `start`, so it stays in flight.
        let runTask = Task { await state.runExe(dir.appendingPathComponent("g.exe"), in: bottle) }
        // Bounded wait so a regression (marker not set) fails cleanly, not hangs.
        var inFlight = false
        for _ in 0 ..< 200 where !inFlight {
            if state.launchingIDs.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                inFlight = true
            }
        }
        #expect(inFlight)
        state.lastErrorMessage = nil
        await state.importGPTK(dmg: dir.appendingPathComponent("eval.dmg"))
        #expect(state.lastErrorMessage != nil)
        #expect(mounter.mounted.isEmpty) // import refused, never mounted

        runner.release()
        await runTask.value
    }

    /// The dropped-exe path registers the program BEFORE launching, so it too
    /// holds a synchronous launch marker for its whole duration — otherwise a
    /// GPTK import racing the register-then-launch window would leave the
    /// program added but never launched (and a re-drop would duplicate it).
    @Test func refusesGPTKImportWhileAnAddAndLaunchIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = GatedLaunchRunner()
        let mounter = FakeMounter(mountPoint: dir)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: runner,
            downloader: FakeDownloader(fixture: fixture),
            mounter: mounter,
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner()
        )
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        let exe = dir.appendingPathComponent("Dropped.exe")
        try Data("MZ".utf8).write(to: exe)

        // Drop-and-launch, gated at wine `start`, so it stays in flight.
        let addTask = Task { await state.addProgramAndLaunch(exe: exe, in: bottle) }
        var inFlight = false
        for _ in 0 ..< 200 where !inFlight {
            if state.launchingIDs.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                inFlight = true
            }
        }
        #expect(inFlight)
        state.lastErrorMessage = nil
        await state.importGPTK(dmg: dir.appendingPathComponent("eval.dmg"))
        #expect(state.lastErrorMessage != nil)
        #expect(mounter.mounted.isEmpty) // import refused, never mounted

        runner.release()
        await addTask.value
    }
}

/// Runner that blocks `wineboot --init` until released, so a test can hold a
/// bottle creation in flight; every other wine command returns immediately.
private final class GatedBootRunner: ProcessRunning, @unchecked Sendable {
    private let released = Mutex<Bool>(false)
    func release() {
        released.withLock { $0 = true }
    }

    func run(
        executable _: URL,
        arguments: [String],
        environment _: [String: String]?,
        currentDirectory _: URL?,
        outputLine _: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        if arguments.first == "wineboot" {
            while !released.withLock({ $0 }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return ProcessResult(exitCode: 0)
    }
}

/// A DMG mounter that blocks on mount until the task is cancelled, so a test can
/// hold a GPTK import in flight (lease held) while it drives another action.
private final class BlockingMounter: DiskImageMounting, @unchecked Sendable {
    private let mountPoint: URL
    init(mountPoint: URL) {
        self.mountPoint = mountPoint
    }

    func mount(dmg _: URL) async throws -> URL {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return mountPoint
    }

    func unmount(_: URL) async {}
}

/// Runner that blocks the program launch (`start /wait`) until released, so a
/// test can hold a program "running" while it drives Stop; every other wine
/// command (taskkill, wineboot, regedit, …) returns immediately.
private final class GatedLaunchRunner: ProcessRunning, @unchecked Sendable {
    private let released = Mutex<Bool>(false)
    func release() {
        released.withLock { $0 = true }
    }

    func run(
        executable _: URL,
        arguments: [String],
        environment _: [String: String]?,
        currentDirectory _: URL?,
        outputLine _: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        if arguments.first == "start" {
            while !released.withLock({ $0 }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return ProcessResult(exitCode: 0)
    }
}
