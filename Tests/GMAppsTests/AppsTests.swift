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
        .appendingPathComponent("gm-apps-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct Env {
    let root: URL
    let runtimeStore: RuntimeStore
    let bottleStore: BottleStore
    let bottle: Bottle
    let runner: FakeRunner

    func launcher() -> WineLauncher {
        WineLauncher(
            runtimeStore: runtimeStore,
            bottleStore: bottleStore,
            runner: runner,
            logsRoot: root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
    }
}

private func makeEnv() async throws -> Env {
    let root = try tempDir()
    let runtimeStore = RuntimeStore(root: root)
    try await runtimeStore.save(RuntimeDescriptor(
        id: "rt",
        displayVersion: "GPTK test",
        wineBinaryRelativePath: "gptk/wine/bin/wine64",
        gptk: .installed(version: "3.0")
    ))
    let bottleStore = BottleStore(root: root)
    let bottle = try await bottleStore.create(name: "Bottle", runtimeID: "rt")
    return Env(root: root, runtimeStore: runtimeStore, bottleStore: bottleStore, bottle: bottle, runner: FakeRunner())
}

@Suite("InstallerCatalog")
struct InstallerCatalogTests {
    @Test func bundledCatalogHasVerifiedSteamEntry() throws {
        let catalog = try InstallerCatalog.bundled()
        let steam = try #require(catalog.entries.first { $0.id == "steam" })
        #expect(steam.name == "Steam")
        #expect(steam.downloadURL.absoluteString
            == "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")
        #expect(steam.installerFileName == "SteamSetup.exe")
        #expect(steam.silentArguments == ["/S"])
        #expect(steam.installedWindowsPath == "C:\\Program Files (x86)\\Steam\\steam.exe")
        #expect(steam.launchArguments == ["-allosarches", "-cef-force-32bit", "-noverifyfiles"])
        let config = try #require(steam.configFiles.first)
        #expect(config.windowsPath == "C:\\Program Files (x86)\\Steam\\steam.cfg")
        #expect(config.contents == "BootStrapperInhibitAll=Enable\n")
    }
}

@Suite("AppInstaller")
struct AppInstallerTests {
    @Test func installsDownloadsRunsConfiguresAndRegisters() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let fixture = env.root.appendingPathComponent("fixture-installer.exe")
        try Data("MZ fake installer".utf8).write(to: fixture)

        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let catalog = try InstallerCatalog.bundled()
        let steam = try #require(catalog.entries.first { $0.id == "steam" })

        let phases = Mutex<[InstallPhase]>([])
        let program = try await installer.install(steam, into: env.bottle) { phase, _ in
            phases.withLock {
                if $0.last != phase {
                    $0.append(phase)
                }
            }
        }

        // Installer ran under wine with silent args, waiting for completion.
        let invocation = try #require(env.runner.invocations.first)
        #expect(invocation.executable.hasSuffix("wine64"))
        #expect(invocation.arguments.prefix(3) == ["start", "/wait", "/unix"])
        #expect(invocation.arguments.last == "/S")
        #expect(invocation.arguments.contains { $0.hasSuffix("SteamSetup.exe") })

        // steam.cfg written into the prefix at the catalog-specified path.
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        let cfg = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.cfg")
        #expect(try String(contentsOf: cfg, encoding: .utf8) == "BootStrapperInhibitAll=Enable\n")

        // Program registered, pinned, with verified launch flags.
        #expect(program.name == "Steam")
        #expect(program.pinned)
        #expect(program.arguments == ["-allosarches", "-cef-force-32bit", "-noverifyfiles"])
        let saved = try await env.bottleStore.list().first
        #expect(saved?.programs == [program])

        #expect(phases.withLock { $0 } == [.downloading, .installing, .configuring, .done])
    }

    @Test func reinstallReplacesExistingProgramInsteadOfDuplicating() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("fixture-installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let steam = try #require(InstallerCatalog.bundled().entries.first { $0.id == "steam" })

        _ = try await installer.install(steam, into: env.bottle, progress: nil)
        let reloaded = try #require(await env.bottleStore.list().first)
        _ = try await installer.install(steam, into: reloaded, progress: nil)

        let final = try #require(await env.bottleStore.list().first)
        #expect(final.programs.count == 1)
    }
}

@Suite("ProgramLibrary")
struct ProgramLibraryTests {
    @Test func addsExternalExeAsZDriveProgramAndRemoves() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let library = ProgramLibrary(bottleStore: env.bottleStore)

        let program = try await library.addProgram(
            exe: URL(fileURLWithPath: "/Users/me/Games/game.exe"),
            name: nil,
            in: env.bottle
        )
        #expect(program.name == "game")
        #expect(program.windowsPath == "Z:\\Users\\me\\Games\\game.exe")
        #expect(program.pinned)
        var saved = try #require(await env.bottleStore.list().first)
        #expect(saved.programs == [program])

        try await library.removeProgram(id: program.id, from: saved)
        saved = try #require(await env.bottleStore.list().first)
        #expect(saved.programs.isEmpty)
    }

    @Test func addsPrefixInternalExeAsCDriveProgram() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let library = ProgramLibrary(bottleStore: env.bottleStore)
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)

        let program = try await library.addProgram(
            exe: prefix.appendingPathComponent("drive_c/Games/app.exe"),
            name: "My App",
            in: env.bottle
        )
        #expect(program.name == "My App")
        #expect(program.windowsPath == "C:\\Games\\app.exe")
    }
}
