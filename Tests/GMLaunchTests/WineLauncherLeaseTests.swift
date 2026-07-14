import Foundation
import GMBottles
import GMModel
import GMRuntime
import GMSystem
import GMTestSupport
import Testing
@testable import GMLaunch

@Suite("WineLauncher runtime lease")
struct WineLauncherLeaseTests {
    private func launcher(runner: FakeRunner, env: Env, lease: RuntimeLease) -> WineLauncher {
        WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: runner,
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt",
            lease: lease
        )
    }

    /// While an import holds the writer, EVERY method that starts a wine process
    /// fails to take a reader and is refused — launch, run, stop, control
    /// commands, taskkill, retina registry, and boot — and no wine process is
    /// ever spawned. This is also the completeness net: a method that forgot to
    /// take a reader would run the runner here and fail the final assertion.
    @Test func refusesEveryWineCallWhileWriterHeld() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let runner = FakeRunner()
        let lease = RuntimeLease()
        #expect(lease.acquireWriter()) // import holds the runtime
        let launcher = launcher(runner: runner, env: env, lease: lease)
        let program = Program(
            name: "Steam",
            windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            arguments: [],
            environment: [:]
        )
        let installer = URL(fileURLWithPath: "/Users/me/Downloads/installer.exe")

        await #expect(throws: LaunchError.runtimeUnderMaintenance) {
            try await launcher.launch(program, in: env.bottle)
        }
        await #expect(throws: LaunchError.runtimeUnderMaintenance) {
            try await launcher.run(exe: installer, arguments: [], in: env.bottle)
        }
        await #expect(throws: LaunchError.runtimeUnderMaintenance) {
            try await launcher.runControlCommand(exe: installer, arguments: ["-shutdown"], in: env.bottle)
        }
        await #expect(throws: LaunchError.runtimeUnderMaintenance) {
            try await launcher.stopAll(in: env.bottle)
        }
        await #expect(throws: LaunchError.runtimeUnderMaintenance) {
            try await launcher.taskkill(imageName: "steam.exe", in: env.bottle)
        }
        await #expect(throws: LaunchError.runtimeUnderMaintenance) {
            try await launcher.applyRetinaRegistry(in: env.bottle)
        }
        await #expect(throws: LaunchError.runtimeUnderMaintenance) {
            try await launcher.initializeBottle(env.bottle)
        }
        #expect(runner.invocations.isEmpty)
    }

    /// With no writer held, wine runs normally and each op takes then drops a
    /// reader (so a later import could proceed).
    @Test func allowsWineCallsWhenNoWriterHeld() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let runner = FakeRunner()
        let lease = RuntimeLease()
        let launcher = launcher(runner: runner, env: env, lease: lease)
        try await launcher.stopAll(in: env.bottle)
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations[0].arguments == ["-k"])
        // The reader was released, so a writer can now be granted.
        #expect(lease.acquireWriter())
    }
}
