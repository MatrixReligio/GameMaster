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
        .appendingPathComponent("gm-appstate-migrate-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a runtime tarball fixture + a matching manifest entry. (File-private
/// by design — the same shape the other AppState suites use.)
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

/// A ready AppState whose bottle needs a one-time Steam migration to a run
/// runtime whose download is gated, so a test can drive the migration and hold
/// it in flight.
@MainActor
private struct MigrationEnv {
    let state: AppState
    let bottle: Bottle
    let steamExe: URL
    let steamWindowsPath: String
    let downloader: GatedDownloader
}

@MainActor
private func makeMigrationEnv(dir: URL) async throws -> MigrationEnv {
    let (fixture, gptkEntry) = try await makeRuntimeFixtureEntry(in: dir)
    // The bundled "steam" entry migrates to a run runtime; make that runtime
    // installable so the migration downloads it — and gate the download.
    let steam = try #require(InstallerCatalog.bundled().entries.first { $0.id == "steam" })
    let runID = try #require(steam.runRuntimeID)
    let runEntry = try RuntimeManifest.Entry(
        id: runID,
        displayVersion: "Run runtime",
        url: #require(URL(string: "https://example.com/run.tar.gz")),
        sha256: SHA256.hexDigest(of: fixture),
        wineBinaryRelativePath: "Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
        bundledGPTKVersion: nil
    )
    let downloader = GatedDownloader(fixture: fixture)
    let state = AppState(
        root: dir.appendingPathComponent("approot"),
        runner: FakeRunner(),
        downloader: downloader,
        mounter: FakeMounter(mountPoint: dir),
        manifest: RuntimeManifest(defaultRuntimeID: gptkEntry.id, entries: [gptkEntry, runEntry]),
        systemToolRunner: SubprocessRunner()
    )
    await state.installDefaultRuntime() // uses the downloader, not yet armed
    await state.createBottle(name: "B")
    let bottle = try #require(state.bottles.first)

    // Pre-bootstrap Steam so the migration skips the (slow) client bootstrap and,
    // once released, finishes promptly. The exe sits at the catalog's Steam path,
    // so launching or dropping it triggers the migration.
    let prefix = await state.bottleStore.prefixDirectory(of: bottle)
    let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
    try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
    let steamExe = steamDir.appendingPathComponent("steam.exe")
    try Data("MZ".utf8).write(to: steamExe)
    try Data(count: 10_000_001).write(to: steamDir.appendingPathComponent("steamui.dll"))
    return MigrationEnv(
        state: state,
        bottle: bottle,
        steamExe: steamExe,
        steamWindowsPath: steam.installedWindowsPath,
        downloader: downloader
    )
}

/// A Steam-bottle migration rewrites the prefix (downloads a run runtime,
/// bootstraps, switches the bottle) — the same class of prefix mutation an
/// install performs. It must hold the bottle's EXCLUSIVE lease, not run under
/// the shared launch lease where a concurrent launch/runExe on the same bottle
/// could touch the prefix mid-migration.
@Suite("AppState Steam migration lease")
@MainActor
struct AppStateMigrationLeaseTests {
    /// Gates a run-runtime migration in flight (blocked at the run-runtime
    /// download) and proves a concurrent runExe on the SAME bottle is refused,
    /// because the migration holds the exclusive lease. Under the old code the
    /// migration ran beneath the shared launch lease, so the concurrent runExe
    /// took a compatible shared lease and slipped into the prefix being migrated.
    @Test func refusesAConcurrentBottleOpWhileASteamMigrationIsInFlight() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = try await makeMigrationEnv(dir: dir)

        env.downloader.arm() // from here, the run-runtime download blocks
        let program = Program(name: "Steam", windowsPath: env.steamWindowsPath)
        let launchTask = Task { await env.state.launch(program: program, in: env.bottle) }

        var inFlight = false
        for _ in 0 ..< 400 where !inFlight {
            if env.downloader.reached {
                inFlight = true
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        #expect(inFlight)
        env.state.lastErrorMessage = nil

        // A concurrent runExe on the same bottle must be refused while the
        // migration holds the exclusive lease.
        let dropped = dir.appendingPathComponent("Other.exe")
        try Data("MZ".utf8).write(to: dropped)
        await env.state.runExe(dropped, in: env.bottle)
        #expect(env.state.lastErrorMessage != nil) // refused: bottle busy

        env.downloader.release()
        await launchTask.value
    }

    /// addProgramAndLaunch registers the dropped exe under the bottle's SHARED
    /// lease, then launches it. When the dropped program needs a Steam migration
    /// — which now takes the bottle EXCLUSIVELY — a still-held shared reader from
    /// the registration would self-block the migration every time. The
    /// registration lease must be released before the launch, so the migration
    /// proceeds (here: reaches its gated run-runtime download) instead of
    /// refusing itself with a bogus "bottle busy".
    @Test func addProgramAndLaunchDoesNotSelfBlockASteamMigration() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = try await makeMigrationEnv(dir: dir)

        env.downloader.arm()
        let launchTask = Task { await env.state.addProgramAndLaunch(exe: env.steamExe, in: env.bottle) }

        var reached = false
        for _ in 0 ..< 400 where !reached {
            if env.downloader.reached {
                reached = true
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        #expect(reached) // migration proceeded past the exclusive acquire — no self-block

        env.downloader.release()
        await launchTask.value
    }
}

/// Downloader that blocks (once `arm()` is called) until released, so a test can
/// hold a run-runtime download — and the migration around it — in flight.
/// `reached` flips once a gated download blocks. Mirrors the GatedStopRunner /
/// GatedRegeditRunner idiom used elsewhere in the suite.
private final class GatedDownloader: Downloading, @unchecked Sendable {
    private let fixture: URL
    private let released = Mutex<Bool>(false)
    private let armed = Mutex<Bool>(false)
    private let reachedDownload = Mutex<Bool>(false)

    var reached: Bool {
        reachedDownload.withLock { $0 }
    }

    init(fixture: URL) {
        self.fixture = fixture
    }

    func arm() {
        armed.withLock { $0 = true }
    }

    func release() {
        released.withLock { $0 = true }
    }

    func download(from _: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        if armed.withLock({ $0 }) {
            reachedDownload.withLock { $0 = true }
            while !released.withLock({ $0 }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
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
