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

        state.maintenanceGate.setActive(true)
        await state.deleteBottle(bottle)
        state.maintenanceGate.setActive(false)

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

        state.maintenanceGate.setActive(true)
        await state.updateBottle(id: bottle.id, name: "Renamed", settings: bottle.settings)
        state.maintenanceGate.setActive(false)

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

        state.maintenanceGate.setActive(true)
        await state.addProgramAndLaunch(exe: exe, in: bottle)
        state.maintenanceGate.setActive(false)

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
