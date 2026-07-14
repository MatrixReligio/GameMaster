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

        // Pre-bootstrap Steam so the migration skips the (slow) client bootstrap
        // and, once released, finishes promptly.
        let prefix = await state.bottleStore.prefixDirectory(of: bottle)
        let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: steamDir.appendingPathComponent("steam.exe"))
        try Data(count: 10_000_001).write(to: steamDir.appendingPathComponent("steamui.dll"))

        downloader.arm() // from here, the run-runtime download blocks
        let program = Program(name: "Steam", windowsPath: steam.installedWindowsPath)
        let launchTask = Task { await state.launch(program: program, in: bottle) }

        var inFlight = false
        for _ in 0 ..< 400 where !inFlight {
            if downloader.reached {
                inFlight = true
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        #expect(inFlight)
        state.lastErrorMessage = nil

        // A concurrent runExe on the same bottle must be refused while the
        // migration holds the exclusive lease.
        let dropped = dir.appendingPathComponent("Other.exe")
        try Data("MZ".utf8).write(to: dropped)
        await state.runExe(dropped, in: bottle)
        #expect(state.lastErrorMessage != nil) // refused: bottle busy

        downloader.release()
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
