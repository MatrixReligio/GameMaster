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

struct Env {
    let root: URL
    let runtimeStore: RuntimeStore
    let bottleStore: BottleStore
    let descriptor: RuntimeDescriptor
    let bottle: Bottle
}

func makeEnv(dxmt: DXMTStatus = .none) async throws -> Env {
    let root = try tempDir()
    let runtimeStore = RuntimeStore(root: root)
    let descriptor = RuntimeDescriptor(
        id: "rt",
        displayVersion: "GPTK test",
        wineBinaryRelativePath: "gptk/wine/bin/wine64",
        gptk: .installed(version: "3.0"),
        dxmt: dxmt
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

/// Places a fake DXMT winemetal.dll inside the test runtime, mirroring the
/// assembled runtime layout (`<wine root>/lib/wine/x86_64-windows/`).
private func writeRuntimeWinemetal(env: Env, contents: String) throws -> URL {
    let dir = env.root.appendingPathComponent(
        "runtimes/rt/gptk/wine/lib/wine/x86_64-windows",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dll = dir.appendingPathComponent("winemetal.dll")
    try Data(contents.utf8).write(to: dll)
    return dll
}

@Suite("LogReader")
struct LogReaderTests {
    @Test func returnsAShortFileWhole() throws {
        let url = try tempDir().appendingPathComponent("log.txt")
        try Data("hello\nworld\n".utf8).write(to: url)
        #expect(LogReader.tail(of: url) == "hello\nworld\n")
    }

    @Test func capsToTheLastBytesOfALongFile() throws {
        let url = try tempDir().appendingPathComponent("big.txt")
        try Data("0123456789ABCDE".utf8).write(to: url) // 15 bytes
        #expect(LogReader.tail(of: url, maxBytes: 5) == "ABCDE")
    }

    @Test func returnsEmptyForAMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-nope-\(UUID().uuidString).log")
        #expect(LogReader.tail(of: missing).isEmpty)
    }

    @Test func returnsEmptyForAnEmptyFile() throws {
        let url = try tempDir().appendingPathComponent("empty.txt")
        try Data().write(to: url)
        #expect(LogReader.tail(of: url).isEmpty)
    }

    @Test func returnsEmptyForZeroMaxBytes() throws {
        let url = try tempDir().appendingPathComponent("some.txt")
        try Data("content".utf8).write(to: url)
        #expect(LogReader.tail(of: url, maxBytes: 0).isEmpty)
    }

    @Test func tailDataCapsALargeFileToMaxBytes() throws {
        let url = try tempDir().appendingPathComponent("big.bin")
        try Data(repeating: 65, count: 10000).write(to: url)
        #expect(LogReader.tailData(of: url, maxBytes: 4096).count == 4096)
    }

    /// A log the game is still writing can grow between measuring its size and
    /// reading it; the result must never exceed the cap. `read(upToCount:)`
    /// guarantees this (the old `readToEnd()` did not).
    @Test func tailDataStaysCappedUnderConcurrentAppend() async throws {
        let url = try tempDir().appendingPathComponent("growing.log")
        let maxBytes = 1024
        try Data(repeating: 65, count: maxBytes * 4).write(to: url) // already over the cap
        // Open the writer inside the task so no non-Sendable handle is captured.
        let appender = Task.detached {
            guard let writer = try? FileHandle(forWritingTo: url) else { return }
            _ = try? writer.seekToEnd()
            for _ in 0 ..< 400 {
                try? writer.write(contentsOf: Data(repeating: 66, count: 8192))
            }
            try? writer.close()
        }
        for _ in 0 ..< 100 {
            #expect(LogReader.tailData(of: url, maxBytes: maxBytes).count <= maxBytes)
        }
        await appender.value
    }
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
            arguments: ["-allosarches", "-noverifyfiles"],
            environment: ["PER_PROGRAM": "yes"]
        )
        let result = try await launcher.launch(program, in: env.bottle)
        #expect(result.exitCode == 0)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable.hasSuffix("runtimes/rt/gptk/wine/bin/wine64"))
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        // Games launch with /wait so the process stays attached for the whole
        // session — that's what makes the "running" indicator accurate.
        #expect(invocation.arguments == [
            "start", "/wait", "/unix",
            prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe").path,
            "-allosarches", "-noverifyfiles"
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

        // wineboot must disable the mono/.NET and gecko/HTML auto-installers so
        // it never tries to download them (which fails with a checksum error).
        let overrides = try #require(runner.invocations[0].environment?["WINEDLLOVERRIDES"])
        #expect(overrides.contains("mscoree="))
        #expect(overrides.contains("mshtml="))
        // The D3DMetal DirectX overrides must survive the merge.
        #expect(overrides.contains("d3d11"))
    }

    /// Graceful stop: taskkill WITHOUT /F sends WM_CLOSE — the Windows-side
    /// equivalent of clicking the window's close button — so programs can
    /// save state or show their own confirmation. stopAll stays the hard kill.
    @Test func taskkillRequestsGracefulClose() async throws {
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
        try await launcher.taskkill(imageName: "game.exe", in: env.bottle)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable.hasSuffix("wine64"))
        #expect(invocation.arguments == ["taskkill", "/IM", "game.exe"])
        #expect(!invocation.arguments.contains("/F"))
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

@Suite("WindowsPath edge cases")
struct WindowsPathEdgeTests {
    private let prefix = URL(fileURLWithPath: "/tmp/b/prefix")

    @Test func driveRootMapsToRootedWindowsPath() {
        // The drive_c root itself must map to "C:\\", not a bare "C:".
        let windows = WindowsPath.toWindows(prefix.appendingPathComponent("drive_c"), prefix: prefix)
        #expect(windows == "C:\\")
    }

    @Test func lowercaseDriveLetterMapsToDosdevices() {
        let unix = WindowsPath.toUnix("d:\\games\\x.exe", prefix: prefix)
        #expect(unix.path == "/tmp/b/prefix/dosdevices/d:/games/x.exe")
    }
}

@Suite("DXMT prefix support")
struct DXMTPrefixSupportTests {
    private func launcher(_ env: Env, runner: FakeRunner = FakeRunner()) -> WineLauncher {
        WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: runner,
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
    }

    private func prefixWinemetal(_ env: Env) async -> URL {
        await env.bottleStore.prefixDirectory(of: env.bottle)
            .appendingPathComponent("drive_c/windows/system32/winemetal.dll")
    }

    /// DXMT's d3d11 builtin loads winemetal.dll; wine resolves that reliably
    /// only when the DLL is also visible in the prefix's system32. Launch must
    /// copy it there from the runtime.
    @Test func launchCopiesWinemetalIntoPrefixSystem32() async throws {
        let env = try await makeEnv(dxmt: .installed(version: "0.80"))
        defer { try? FileManager.default.removeItem(at: env.root) }
        _ = try writeRuntimeWinemetal(env: env, contents: "DXMT winemetal")

        _ = try await launcher(env).launch(
            Program(name: "Game", windowsPath: "C:\\game.exe"),
            in: env.bottle
        )
        let target = await prefixWinemetal(env)
        #expect(try String(contentsOf: target, encoding: .utf8) == "DXMT winemetal")
    }

    /// Same-size copies are left alone (idempotent re-launch), but a runtime
    /// upgrade (different size) must replace the stale prefix copy.
    @Test func launchReplacesOnlyMismatchedWinemetal() async throws {
        let env = try await makeEnv(dxmt: .installed(version: "0.80"))
        defer { try? FileManager.default.removeItem(at: env.root) }
        _ = try writeRuntimeWinemetal(env: env, contents: "AAAA")

        let target = await prefixWinemetal(env)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("BBBB".utf8).write(to: target)

        let launcher = launcher(env)
        let program = Program(name: "Game", windowsPath: "C:\\game.exe")
        _ = try await launcher.launch(program, in: env.bottle)
        // Same size — the existing copy stays.
        #expect(try String(contentsOf: target, encoding: .utf8) == "BBBB")

        _ = try writeRuntimeWinemetal(env: env, contents: "AAAA v2 longer")
        _ = try await launcher.launch(program, in: env.bottle)
        #expect(try String(contentsOf: target, encoding: .utf8) == "AAAA v2 longer")
    }

    @Test func launchWithoutDXMTLeavesPrefixAlone() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        _ = try writeRuntimeWinemetal(env: env, contents: "DXMT winemetal")

        _ = try await launcher(env).launch(
            Program(name: "Game", windowsPath: "C:\\game.exe"),
            in: env.bottle
        )
        let target = await prefixWinemetal(env)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// A winemetal placement failure must not be swallowed: DXMT's d3d11/dxgi
    /// load winemetal.dll by name, so a game launched without it renders broken.
    /// The launch surfaces the error instead of starting into a broken game.
    @Test func launchSurfacesDXMTPrepFailure() async throws {
        let env = try await makeEnv(dxmt: .installed(version: "0.80"))
        defer { try? FileManager.default.removeItem(at: env.root) }
        _ = try writeRuntimeWinemetal(env: env, contents: "DXMT winemetal")
        // Force the placement to fail: a FILE sits where system32 must be created.
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: windows.appendingPathComponent("system32"))

        await #expect(throws: (any Error).self) {
            _ = try await launcher(env).launch(Program(name: "Game", windowsPath: "C:\\game.exe"), in: env.bottle)
        }
    }

    /// Stopping must never depend on DXMT file prep: a bottle whose winemetal
    /// placement fails must still be stoppable. `taskkill` and `stopAll` get a
    /// plain runtime context and never run the (throwing) prep — even though a
    /// launch of the same bottle surfaces the failure.
    @Test func stopCommandsIgnoreDXMTPrepFailure() async throws {
        let env = try await makeEnv(dxmt: .installed(version: "0.80"))
        defer { try? FileManager.default.removeItem(at: env.root) }
        _ = try writeRuntimeWinemetal(env: env, contents: "DXMT winemetal")
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: windows.appendingPathComponent("system32"))

        let launcher = launcher(env)
        // Stop paths must succeed despite the broken DXMT prep.
        try await launcher.stopAll(in: env.bottle)
        try await launcher.taskkill(imageName: "game.exe", in: env.bottle)
        // A launch of the same bottle still surfaces the prep failure.
        await #expect(throws: (any Error).self) {
            _ = try await launcher.launch(Program(name: "Game", windowsPath: "C:\\game.exe"), in: env.bottle)
        }
    }
}

@Suite("MetalFX preparation on launch")
struct MetalFXLaunchTests {
    /// GPTK ships DLSS-to-MetalFX shims as nvngx-on-metalfx.{so,dll}; enabling
    /// the bottle's MetalFX toggle must activate them (rename + copy into the
    /// prefix) before the game starts.
    @Test func launchWithMetalFXPreparesGPTKShims() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let lib = env.root.appendingPathComponent("runtimes/rt/gptk/wine/lib")
        try FileManager.default.createDirectory(
            at: lib.appendingPathComponent("wine/x86_64-unix"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: lib.appendingPathComponent("wine/x86_64-windows"), withIntermediateDirectories: true
        )
        try Data("so".utf8).write(to: lib.appendingPathComponent("wine/x86_64-unix/nvngx-on-metalfx.so"))
        try Data("dll".utf8).write(to: lib.appendingPathComponent("wine/x86_64-windows/nvngx-on-metalfx.dll"))
        try Data("nvapi".utf8).write(to: lib.appendingPathComponent("wine/x86_64-windows/nvapi64.dll"))

        var bottle = env.bottle
        bottle.settings.metalFX = true
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: FakeRunner(),
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        _ = try await launcher.launch(Program(name: "G", windowsPath: "C:\\g.exe"), in: bottle)

        #expect(FileManager.default.fileExists(
            atPath: lib.appendingPathComponent("wine/x86_64-unix/nvngx.so").path
        ))
        let prefix = await env.bottleStore.prefixDirectory(of: bottle)
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        #expect(FileManager.default.fileExists(atPath: system32.appendingPathComponent("nvngx.dll").path))
        #expect(FileManager.default.fileExists(atPath: system32.appendingPathComponent("nvapi64.dll").path))
    }

    @Test func launchWithoutMetalFXLeavesShimsAlone() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let unixDir = env.root.appendingPathComponent("runtimes/rt/gptk/wine/lib/wine/x86_64-unix")
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try Data("so".utf8).write(to: unixDir.appendingPathComponent("nvngx-on-metalfx.so"))

        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: FakeRunner(),
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        _ = try await launcher.launch(Program(name: "G", windowsPath: "C:\\g.exe"), in: env.bottle)
        #expect(!FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("nvngx.so").path))
    }

    /// A MetalFX preparation failure must not be swallowed: launching with the
    /// env claiming MetalFX is on while the shim silently failed to install
    /// leaves the user with a feature that doesn't work and no signal. The
    /// launch surfaces the error instead.
    @Test func launchSurfacesMetalFXPrepFailure() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let winDir = env.root.appendingPathComponent("runtimes/rt/gptk/wine/lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: winDir.appendingPathComponent("nvngx-on-metalfx.dll"))

        // Force prep to fail: a FILE sits where the prefix's system32 must be created.
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: windows.appendingPathComponent("system32"))

        var bottle = env.bottle
        bottle.settings.metalFX = true
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: FakeRunner(),
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        await #expect(throws: (any Error).self) {
            _ = try await launcher.launch(Program(name: "G", windowsPath: "C:\\g.exe"), in: bottle)
        }
    }

    /// Stopping must never depend on MetalFX file preparation: a bottle whose
    /// MetalFX shims are broken must still be stoppable. `taskkill` and
    /// `stopAll` get a plain runtime context and never run the (throwing) prep,
    /// even though a launch of the same bottle surfaces the prep failure.
    @Test func stopCommandsIgnoreBrokenMetalFXPrep() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let winDir = env.root.appendingPathComponent("runtimes/rt/gptk/wine/lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: winDir.appendingPathComponent("nvngx-on-metalfx.dll"))

        // Broken prep: a FILE sits where the prefix's system32 must be created.
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: windows.appendingPathComponent("system32"))

        var bottle = env.bottle
        bottle.settings.metalFX = true
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: FakeRunner(),
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        // Stop paths must succeed despite the broken MetalFX prep.
        try await launcher.stopAll(in: bottle)
        try await launcher.taskkill(imageName: "g.exe", in: bottle)
        // A launch of the same bottle still surfaces the prep failure.
        await #expect(throws: (any Error).self) {
            _ = try await launcher.launch(Program(name: "G", windowsPath: "C:\\g.exe"), in: bottle)
        }
    }

    /// A control command routed through the running instance (Steam's
    /// `-shutdown`) must also never run MetalFX prep — it goes through the
    /// launcher but is a stop, not a launch, so a broken MetalFX file can't
    /// block it. (`run`, used for launching one-off programs and installers,
    /// still preps.)
    @Test func runControlCommandIgnoresBrokenMetalFXPrep() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let winDir = env.root.appendingPathComponent("runtimes/rt/gptk/wine/lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: winDir.appendingPathComponent("nvngx-on-metalfx.dll"))

        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: windows.appendingPathComponent("system32"))

        var bottle = env.bottle
        bottle.settings.metalFX = true
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: FakeRunner(),
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        let exe = prefix.appendingPathComponent("drive_c/steam.exe")
        // The control command must succeed despite broken MetalFX prep…
        _ = try await launcher.runControlCommand(exe: exe, arguments: ["-shutdown"], in: bottle)
        // …while `run` (a launch path) still surfaces the prep failure.
        await #expect(throws: (any Error).self) {
            _ = try await launcher.run(exe: exe, arguments: [], in: bottle)
        }
    }
}

@Suite("Launch argument sanitizing")
struct LaunchArgumentSanitizingTests {
    @Test func stripsDeadCefForce32bitFromLegacyPrograms() async throws {
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
        // A bottle created by an old app version pinned Steam with the dead flag.
        let legacy = Program(
            name: "Steam",
            windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            arguments: ["-allosarches", "-cef-force-32bit", "-noverifyfiles"]
        )
        _ = try await launcher.launch(legacy, in: env.bottle)
        let invocation = try #require(runner.invocations.first)
        #expect(!invocation.arguments.contains("-cef-force-32bit"))
        #expect(invocation.arguments.contains("-allosarches"))
        #expect(invocation.arguments.contains("-noverifyfiles"))
    }
}
