import Foundation
import GMBottles
import GMModel
import GMRuntime
import GMSystem
import GMTestSupport
import Testing
@testable import GMLaunch

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-launch-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct Env {
    let root: URL
    let runtimeStore: RuntimeStore
    let bottleStore: BottleStore
    let descriptor: RuntimeDescriptor
    let bottle: Bottle
}

private func makeEnv() async throws -> Env {
    let root = try tempDir()
    let runtimeStore = RuntimeStore(root: root)
    let descriptor = RuntimeDescriptor(
        id: "rt",
        displayVersion: "GPTK test",
        wineBinaryRelativePath: "gptk/wine/bin/wine64",
        gptk: .installed(version: "3.0")
    )
    try await runtimeStore.save(descriptor)
    let bottleStore = BottleStore(root: root)
    let bottle = try await bottleStore.create(name: "Test Bottle", runtimeID: "rt")
    return Env(
        root: root,
        runtimeStore: runtimeStore,
        bottleStore: bottleStore,
        descriptor: descriptor,
        bottle: bottle
    )
}

@Suite("WindowsPath")
struct WindowsPathTests {
    private let prefix = URL(fileURLWithPath: "/tmp/b/prefix")

    @Test func cDriveMapsIntoPrefix() {
        let unix = WindowsPath.toUnix("C:\\Program Files (x86)\\Steam\\steam.exe", prefix: prefix)
        #expect(unix.path == "/tmp/b/prefix/drive_c/Program Files (x86)/Steam/steam.exe")
    }

    @Test func zDriveMapsToRoot() {
        let unix = WindowsPath.toUnix("Z:\\Users\\me\\game.exe", prefix: prefix)
        #expect(unix.path == "/Users/me/game.exe")
    }

    @Test func unixInsidePrefixMapsToCDrive() {
        let windows = WindowsPath.toWindows(
            URL(fileURLWithPath: "/tmp/b/prefix/drive_c/windows/system32/notepad.exe"),
            prefix: prefix
        )
        #expect(windows == "C:\\windows\\system32\\notepad.exe")
    }

    @Test func unixOutsidePrefixMapsToZDrive() {
        let windows = WindowsPath.toWindows(URL(fileURLWithPath: "/Users/me/game.exe"), prefix: prefix)
        #expect(windows == "Z:\\Users\\me\\game.exe")
    }
}

@Suite("RunningTracker")
struct RunningTrackerTests {
    @Test func tracksLifecycle() async {
        let tracker = RunningTracker()
        let id = UUID()
        #expect(await tracker.isRunning(id) == false)
        await tracker.markStarted(programID: id)
        #expect(await tracker.isRunning(id) == true)
        #expect(await tracker.runningIDs == [id])
        await tracker.markStopped(programID: id)
        #expect(await tracker.isRunning(id) == false)
        #expect(await tracker.runningIDs.isEmpty)
    }
}

@Suite("WineLauncher")
struct WineLauncherTests {
    @Test func launchRunsWineStartUnixWithComposedEnvironmentAndLogs() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let runner = FakeRunner(stdoutScripts: [["fake wine output", "second line"]])
        let logsRoot = env.root.appendingPathComponent("logs")
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: runner,
            logsRoot: logsRoot,
            defaultRuntimeID: "rt"
        )
        let program = Program(
            name: "Steam",
            windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            arguments: ["-allosarches", "-cef-force-32bit"],
            environment: ["PER_PROGRAM": "yes"]
        )
        let result = try await launcher.launch(program, in: env.bottle)
        #expect(result.exitCode == 0)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable.hasSuffix("runtimes/rt/gptk/wine/bin/wine64"))
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        #expect(invocation.arguments == [
            "start", "/unix",
            prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path,
            "-allosarches", "-cef-force-32bit"
        ])
        let procEnv = try #require(invocation.environment)
        #expect(procEnv["WINEPREFIX"] == prefix.path)
        #expect(procEnv["WINEESYNC"] == "1")
        #expect(procEnv["WINEDLLOVERRIDES"] == "d3d9,d3d10core,d3d11,d3d12,d3d12core,dxgi=n,b")
        #expect(procEnv["PER_PROGRAM"] == "yes")

        // Output captured to a log file under logs/<bottle-id>/.
        let bottleLogs = logsRoot.appendingPathComponent(env.bottle.id.uuidString)
        let logFiles = try FileManager.default.contentsOfDirectory(atPath: bottleLogs.path)
        #expect(logFiles.count == 1)
        let content = try String(
            contentsOf: bottleLogs.appendingPathComponent(#require(logFiles.first)),
            encoding: .utf8
        )
        #expect(content.contains("fake wine output"))
        #expect(content.contains("second line"))
    }

    @Test func runArbitraryExecutable() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let runner = FakeRunner()
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: runner,
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        _ = try await launcher.run(
            exe: URL(fileURLWithPath: "/Users/me/Downloads/installer.exe"),
            arguments: ["/S"],
            in: env.bottle
        )
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.arguments == ["start", "/unix", "/Users/me/Downloads/installer.exe", "/S"])
    }

    @Test func initializeBottleBootsAndAppliesRetina() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let runner = FakeRunner()
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: runner,
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        try await launcher.initializeBottle(env.bottle)
        #expect(runner.invocations.count == 2)
        #expect(runner.invocations[0].arguments == ["wineboot", "--init"])
        let regedit = runner.invocations[1]
        #expect(regedit.arguments.first == "regedit")
        #expect(regedit.arguments.count == 3)
        #expect(regedit.arguments[1] == "/S")
        #expect(runner.invocations.allSatisfy { $0.environment?["WINEPREFIX"] != nil })
    }

    @Test func stopAllKillsWineserver() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let runner = FakeRunner()
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: runner,
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        try await launcher.stopAll(in: env.bottle)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable.hasSuffix("runtimes/rt/gptk/wine/bin/wineserver"))
        #expect(invocation.arguments == ["-k"])
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        #expect(invocation.environment?["WINEPREFIX"] == prefix.path)
    }

    @Test func missingRuntimeThrows() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let bottle = try await env.bottleStore.create(name: "Orphan", runtimeID: "nonexistent")
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: FakeRunner(),
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        await #expect(throws: LaunchError.self) {
            _ = try await launcher.run(exe: URL(fileURLWithPath: "/x.exe"), arguments: [], in: bottle)
        }
    }
}
