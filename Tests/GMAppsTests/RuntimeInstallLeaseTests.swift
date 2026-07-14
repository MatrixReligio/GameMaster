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
        .appendingPathComponent("gm-runtime-install-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

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

/// Blocks the runtime download until released, so a test can hold a runtime
/// install in flight; `reachedDownload` flips once the download blocks.
private final class GatedRuntimeDownloader: Downloading, @unchecked Sendable {
    let fixture: URL
    private let released = Mutex<Bool>(false)
    private let reached = Mutex<Bool>(false)
    var reachedDownload: Bool {
        reached.withLock { $0 }
    }

    init(fixture: URL) {
        self.fixture = fixture
    }

    func release() {
        released.withLock { $0 = true }
    }

    func download(from _: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        reached.withLock { $0 = true }
        while !released.withLock({ $0 }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: fixture, to: destination)
        progress?(1.0)
    }
}

@Suite("Runtime install lease")
@MainActor
struct RuntimeInstallLeaseTests {
    /// Installing the default runtime replaces the runtime directory, so it must
    /// hold the RuntimeLease writer for its whole duration — a second install and
    /// any wine op (here, bottle creation) are refused while it runs.
    @Test func installDefaultRuntimeHoldsWriterAndRefusesConcurrentWork() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, entry) = try await makeRuntimeFixtureEntry(in: dir)
        let downloader = GatedRuntimeDownloader(fixture: fixture)
        let state = AppState(
            root: dir.appendingPathComponent("approot"),
            runner: FakeRunner(),
            downloader: downloader,
            mounter: FakeMounter(mountPoint: dir),
            manifest: RuntimeManifest(defaultRuntimeID: entry.id, entries: [entry]),
            systemToolRunner: SubprocessRunner()
        )

        let installTask = Task { await state.installDefaultRuntime() }
        var inFlight = false
        for _ in 0 ..< 200 where !inFlight {
            if downloader.reachedDownload {
                inFlight = true
            } else {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        #expect(inFlight)
        #expect(state.runtimeMaintenanceInProgress) // writer held for the whole install

        // A second install and a bottle creation are both refused while it runs.
        state.lastErrorMessage = nil
        await state.installDefaultRuntime()
        await state.createBottle(name: "X")
        #expect(state.bottles.isEmpty) // neither ran

        downloader.release()
        await installTask.value
        #expect(state.runtimeMaintenanceInProgress == false) // writer released
    }
}
