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
        .appendingPathComponent("gm-appstate-maint-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a runtime tarball fixture + a matching manifest entry.
/// (File-private by design — the same shape AppStateTests/AppStateGuardTests use.)
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

/// A GPTK import holds the maintenance lease, and the single arbiter in
/// WineLauncher already refuses every wine call during it. These guards are the
/// front door: the three bottle/program entry points refuse cleanly BEFORE
/// doing any partial work — no half-done rename, no orphaned delete, no
/// added-then-unlaunched program that a retry would duplicate.
@Suite("AppState maintenance guards")
@MainActor
struct AppStateMaintenanceGuardTests {
    private struct Ready {
        let dir: URL
        let state: AppState
        let bottle: Bottle
    }

    private func readyStateWithBottle() async throws -> Ready {
        let dir = try tempDir()
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let state = makeState(dir: dir, fixture: fixture, entry: entry, runner: FakeRunner())
        await state.installDefaultRuntime()
        await state.createBottle(name: "B")
        let bottle = try #require(state.bottles.first)
        state.lastErrorMessage = nil
        return Ready(dir: dir, state: state, bottle: bottle)
    }

    /// deleteBottle's `try? stopAll` swallows the arbiter's refusal, so without
    /// a front-door guard the bottle would be deleted mid-maintenance anyway.
    @Test func deleteBottleRefusedDuringRuntimeMaintenance() async throws {
        let ready = try await readyStateWithBottle()
        let state = ready.state
        let bottle = ready.bottle
        defer { try? FileManager.default.removeItem(at: ready.dir) }

        #expect(state.runtimeLease.acquireWriter())
        await state.deleteBottle(bottle)
        state.runtimeLease.releaseWriter()

        #expect(state.lastErrorMessage != nil)
        #expect(state.bottles.contains { $0.id == bottle.id }) // NOT deleted

        // With maintenance over, deleting works again.
        state.lastErrorMessage = nil
        await state.deleteBottle(bottle)
        #expect(!state.bottles.contains { $0.id == bottle.id })
    }

    /// A name-only save touches no wine process, so the arbiter never fires —
    /// only the front-door guard keeps a bottle edit from landing mid-import.
    @Test func updateBottleRefusedDuringRuntimeMaintenance() async throws {
        let ready = try await readyStateWithBottle()
        let state = ready.state
        let bottle = ready.bottle
        defer { try? FileManager.default.removeItem(at: ready.dir) }

        #expect(state.runtimeLease.acquireWriter())
        await state.updateBottle(id: bottle.id, name: "Renamed", settings: bottle.settings)
        state.runtimeLease.releaseWriter()

        #expect(state.lastErrorMessage != nil)
        let store = BottleStore(root: ready.dir.appendingPathComponent("approot"))
        let onDisk = try #require(await store.list().first { $0.id == bottle.id })
        #expect(onDisk.name == "B") // rename did NOT land
    }

    /// addProgramAndLaunch adds to the library BEFORE launching, so without a
    /// front-door guard a maintenance-blocked launch would leave the program
    /// registered — and re-dropping the same exe would duplicate it.
    @Test func addProgramAndLaunchRefusedDuringRuntimeMaintenance() async throws {
        let ready = try await readyStateWithBottle()
        let state = ready.state
        let bottle = ready.bottle
        defer { try? FileManager.default.removeItem(at: ready.dir) }
        let before = try #require(state.bottles.first { $0.id == bottle.id }).programs.count
        let exe = ready.dir.appendingPathComponent("Dropped.exe")
        try Data("MZ".utf8).write(to: exe)

        #expect(state.runtimeLease.acquireWriter())
        await state.addProgramAndLaunch(exe: exe, in: bottle)
        state.runtimeLease.releaseWriter()

        #expect(state.lastErrorMessage != nil)
        let store = BottleStore(root: ready.dir.appendingPathComponent("approot"))
        let onDisk = try #require(await store.list().first { $0.id == bottle.id })
        #expect(onDisk.programs.count == before) // nothing was registered
    }

    /// deleteBottle's stopAll (wineserver -k) and delete run after awaits, so a
    /// GPTK import could otherwise start mid-delete. deleteBottle now holds the
    /// bottle's busy lock synchronously for its whole duration, and the import
    /// refuses while any bottle is busy — closing the last guard-then-await hole.
    @Test func refusesGPTKImportWhileADeleteIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = GatedStopRunner()
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

        // Delete, gated at wineserver -k, so it stays in flight.
        let deleteTask = Task { await state.deleteBottle(bottle) }
        var inFlight = false
        for _ in 0 ..< 200 where !inFlight {
            if runner.reached {
                inFlight = true
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        #expect(inFlight)
        state.lastErrorMessage = nil
        await state.importGPTK(dmg: dir.appendingPathComponent("eval.dmg"))
        #expect(state.lastErrorMessage != nil)
        #expect(mounter.mounted.isEmpty) // import refused, never mounted

        runner.release()
        await deleteTask.value
    }

    /// The point of the reader/writer lease: updateBottle needs NO synchronous
    /// marker of its own. Its retina regedit takes a reader for the whole call,
    /// so while that regedit is in flight a GPTK import can't take the writer —
    /// the check-then-await window inside `context()` is closed structurally,
    /// not by any AppState UI-state set.
    @Test func refusesGPTKImportWhileAnUpdateBottleRegeditIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let runner = GatedRegeditRunner()
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
        #expect(bottle.settings.retinaMode) // default on
        runner.arm() // only gate the retina regedit, not bottle creation's

        // Toggle retina → updateBottle runs applyRetinaRegistry → regedit blocks,
        // holding a runtime reader for the duration.
        var settings = bottle.settings
        settings.retinaMode = false
        let updateTask = Task { await state.updateBottle(id: bottle.id, name: bottle.name, settings: settings) }
        var inFlight = false
        for _ in 0 ..< 200 where !inFlight {
            if runner.reached {
                inFlight = true
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        #expect(inFlight)
        state.lastErrorMessage = nil
        await state.importGPTK(dmg: dir.appendingPathComponent("eval.dmg"))
        #expect(state.lastErrorMessage != nil)
        #expect(mounter.mounted.isEmpty) // import refused, never mounted

        runner.release()
        await updateTask.value
    }

    // MARK: - Reverse guards: a delete in flight excludes other bottle ops

    /// deleteBottle takes the bottle's EXCLUSIVE lease before its first await and
    /// holds it across stopAll. These prove install / launch / settings-save on
    /// the SAME bottle are refused while that delete is in flight — the reverse
    /// direction the old busyBottleIDs set never covered.
    private struct DeleteInFlight {
        let state: AppState
        let bottle: Bottle
        let task: Task<Void, Never>
    }

    private func deleteInFlight(dir: URL, runner: GatedStopRunner) async throws -> DeleteInFlight {
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
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
        let deleteTask = Task { await state.deleteBottle(bottle) }
        var inFlight = false
        for _ in 0 ..< 200 where !inFlight {
            if runner.reached {
                inFlight = true
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        #expect(inFlight)
        state.lastErrorMessage = nil
        return DeleteInFlight(state: state, bottle: bottle, task: deleteTask)
    }

    @Test func refusesInstallWhileADeleteIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = GatedStopRunner()
        let flight = try await deleteInFlight(dir: dir, runner: runner)

        await flight.state.installCatalogApp(id: "steam", into: flight.bottle)
        #expect(flight.state.lastErrorMessage != nil)
        #expect(flight.state.activeInstall == nil) // install never started

        runner.release()
        await flight.task.value
    }

    @Test func refusesLaunchWhileADeleteIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = GatedStopRunner()
        let flight = try await deleteInFlight(dir: dir, runner: runner)

        let program = Program(name: "Game", windowsPath: "C:\\game.exe")
        await flight.state.launch(program: program, in: flight.bottle)
        #expect(flight.state.lastErrorMessage != nil)
        #expect(!flight.state.runningIDs.contains(program.id)) // launch never started

        runner.release()
        await flight.task.value
    }

    @Test func refusesSettingsSaveWhileADeleteIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = GatedStopRunner()
        let flight = try await deleteInFlight(dir: dir, runner: runner)

        await flight.state.updateBottle(id: flight.bottle.id, name: "Renamed", settings: flight.bottle.settings)
        #expect(flight.state.lastErrorMessage != nil)

        runner.release()
        await flight.task.value
        // The delete won, so the bottle (and the would-be rename) is gone.
        #expect(!flight.state.bottles.contains { $0.id == flight.bottle.id })
    }
}

/// Runner that blocks `wineserver -k` until released, so a test can hold a
/// bottle delete in flight; `reached` flips once the stop actually blocks.
private final class GatedStopRunner: ProcessRunning, @unchecked Sendable {
    private let released = Mutex<Bool>(false)
    private let reachedStop = Mutex<Bool>(false)
    var reached: Bool {
        reachedStop.withLock { $0 }
    }

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
        if arguments.first == "-k" {
            reachedStop.withLock { $0 = true }
            while !released.withLock({ $0 }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return ProcessResult(exitCode: 0)
    }
}

/// Runner that blocks `regedit` until released — but only once `arm()` is called,
/// so a test can let bottle creation's own regedit through, then hold a LATER
/// retina regedit in flight. `reached` flips once that gated regedit blocks.
private final class GatedRegeditRunner: ProcessRunning, @unchecked Sendable {
    private let released = Mutex<Bool>(false)
    private let armed = Mutex<Bool>(false)
    private let reachedRegedit = Mutex<Bool>(false)
    var reached: Bool {
        reachedRegedit.withLock { $0 }
    }

    func arm() {
        armed.withLock { $0 = true }
    }

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
        if arguments.first == "regedit", armed.withLock({ $0 }) {
            reachedRegedit.withLock { $0 = true }
            while !released.withLock({ $0 }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return ProcessResult(exitCode: 0)
    }
}
