import Foundation
import GMBottles
import GMModel
import GMRuntime
import GMSystem
import GMTestSupport
import Testing
@testable import GMLaunch

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
