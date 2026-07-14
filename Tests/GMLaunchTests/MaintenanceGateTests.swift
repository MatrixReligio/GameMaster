import Foundation
import GMBottles
import GMModel
import GMRuntime
import GMSystem
import GMTestSupport
import Testing
@testable import GMLaunch

@Suite("WineLauncher maintenance gate")
struct WineLauncherMaintenanceTests {
    private func launcher(runner: FakeRunner, env: Env, underMaintenance: Bool) -> WineLauncher {
        WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: runner,
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt",
            isUnderMaintenance: { underMaintenance }
        )
    }

    /// The single arbiter: while the gate reports maintenance, EVERY wine entry
    /// point is refused at the `context(for:)` choke point — launch, run,
    /// stop, control commands, taskkill, retina registry, and boot — and no
    /// wine process is ever spawned. A GPTK import replacing the shared runtime
    /// must never race a live wine process, whatever the entry point.
    @Test func refusesEveryWineCallWhileMaintenanceHeld() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let runner = FakeRunner()
        let launcher = launcher(runner: runner, env: env, underMaintenance: true)
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

    /// The gate is inert when it reports no maintenance: wine runs normally.
    @Test func allowsWineCallsWhenNotUnderMaintenance() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let runner = FakeRunner()
        let launcher = launcher(runner: runner, env: env, underMaintenance: false)
        try await launcher.stopAll(in: env.bottle)
        #expect(runner.invocations.count == 1)
        #expect(runner.invocations[0].arguments == ["-k"])
    }
}
