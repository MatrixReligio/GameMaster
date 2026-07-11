import Foundation
import GMBottles
import GMModel
import GMRuntime
import GMSystem
import GMTestSupport
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

        // Simulate the installer producing steam.exe so the completion check passes.
        let prefix = dir.appendingPathComponent("approot/bottles/\(bottle.id.uuidString)/prefix")
        let steamExe = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
        try FileManager.default.createDirectory(
            at: steamExe.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("MZ".utf8).write(to: steamExe)

        await state.installCatalogApp(id: "steam", into: bottle)
        #expect(state.lastErrorMessage == nil)
        let updated = try #require(state.bottles.first)
        #expect(updated.programs.count == 1)
        #expect(updated.programs.first?.name == "Steam")
        #expect(updated.programs.first?.pinned == true)
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
