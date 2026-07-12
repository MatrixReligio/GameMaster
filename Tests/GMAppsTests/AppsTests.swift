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
    // The bundled Steam entry switches the bottle to this run runtime after
    // bootstrap; register it so post-switch launches/reinstalls resolve it.
    try await runtimeStore.save(RuntimeDescriptor(
        id: "sikarugir-10.0-6-dxmt-0.80",
        displayVersion: "Sikarugir test",
        wineBinaryRelativePath: "wswine.bundle/bin/wine",
        gptk: .none,
        dxmt: .installed(version: "0.80")
    ))
    let bottleStore = BottleStore(root: root)
    let bottle = try await bottleStore.create(name: "Bottle", runtimeID: "rt")
    return Env(root: root, runtimeStore: runtimeStore, bottleStore: bottleStore, bottle: bottle, runner: FakeRunner())
}

private func steamDirectory(in prefix: URL) -> URL {
    prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
}

/// Writes steam.exe plus a steamui.dll large enough to satisfy the installer's
/// bootstrap-ready poll, so unit tests skip the (real, minutes-long) download.
private func writeBootstrappedSteam(in prefix: URL, exe: Data = Data("MZ".utf8)) throws {
    let steamDir = steamDirectory(in: prefix)
    try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
    try exe.write(to: steamDir.appendingPathComponent("steam.exe"))
    try Data(count: 10_000_001).write(to: steamDir.appendingPathComponent("steamui.dll"))
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
        // -cef-force-32bit is a dead 2023 workaround: Steam removed 32-bit CEF
        // in 2024, and passing it now sends steamwebhelper into an infinite
        // restart loop ("not responding"). Verified by reproduction.
        #expect(steam.launchArguments == ["-allosarches", "-noverifyfiles"])
        #expect(!steam.launchArguments.contains("-cef-force-32bit"))
        // No pre-written config files: steam.cfg (BootStrapperInhibitAll) at
        // install time blocks Steam's FIRST bootstrap update, so steamui.dll
        // never downloads and the client dies with "Failed to load steamui.dll".
        #expect(steam.configFiles.isEmpty)
    }

    @Test func steamEntryCarriesDualRuntimeBootstrapAndWrapper() throws {
        let steam = try #require(InstallerCatalog.bundled().entries.first { $0.id == "steam" })
        // Steam bootstraps under the default (GPTK) runtime, then runs under a
        // Sikarugir Wine 10 that both completes the CEF handshake AND ships
        // DXMT builtins, so D3D11 games (CS2) actually render via Metal.
        #expect(steam.runRuntimeID == "sikarugir-10.0-6-dxmt-0.80")
        // Performance tuning applied when the bottle switches to the run
        // runtime: msync (Mach-port sync, faster than esync on CX-derived
        // builds) and Rosetta AVX (Source 2 has AVX-optimized paths).
        let tuning = try #require(steam.runTuning)
        #expect(tuning.sync == .msync)
        #expect(tuning.advertiseAVX == true)
        let bootstrap = try #require(steam.bootstrap)
        #expect(bootstrap.readyWindowsPath == "C:\\Program Files (x86)\\Steam\\steamui.dll")
        #expect(bootstrap.readyMinBytes > 0)
        #expect(bootstrap.timeoutSeconds > 0)
        // The bootstrap MUST NOT pass -noverifyfiles: a fresh install is only a
        // stub Steam.exe, and skipping verification makes the bootstrapper skip
        // the client download entirely — steam.exe then dies with "Failed to
        // load steamui.dll". Verification IS the first-run download trigger.
        let bootstrapArguments = try #require(bootstrap.launchArguments)
        #expect(!bootstrapArguments.contains("-noverifyfiles"))
        #expect(bootstrapArguments.contains("-allosarches"))
        let wrapper = try #require(steam.webhelperWrapper)
        #expect(wrapper.helperFileName == "steamwebhelper.exe")
        #expect(wrapper.realHelperFileName == "steamwebhelper_real.exe")
        #expect(wrapper.wrapperResourceName == "steamwebhelper_wrapper")
        // The crashing 32-bit service is stubbed at both of its locations.
        let stub = try #require(steam.serviceStub)
        #expect(stub.stubResourceName == "steamservice_stub")
        #expect(stub.windowsPaths.contains("C:\\Program Files (x86)\\Steam\\bin\\SteamService.exe"))
        #expect(stub.windowsPaths.contains("C:\\Program Files (x86)\\Common Files\\Steam\\steamservice.exe"))
    }

    @Test func entriesWithoutOptionalFieldsStillDecode() throws {
        let json = """
        {"entries":[{"id":"x","name":"X","downloadURL":"https://e/x.exe",
        "installerFileName":"x.exe","silentArguments":["/S"],
        "installedWindowsPath":"C:\\\\x.exe","launchArguments":[],"configFiles":[]}]}
        """
        let catalog = try JSONDecoder().decode(InstallerCatalog.self, from: Data(json.utf8))
        let entry = try #require(catalog.entries.first)
        #expect(entry.bootstrap == nil)
        #expect(entry.webhelperWrapper == nil)
        #expect(entry.runRuntimeID == nil)
        #expect(entry.runTuning == nil)
        #expect(entry.configFiles.isEmpty)
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

        // Simulate the installer producing steam.exe plus an already-downloaded
        // steamui.dll (the FakeRunner is a no-op, so the bootstrap poll would
        // otherwise never see the client appear).
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        try writeBootstrappedSteam(in: prefix)

        let phases = Mutex<[InstallPhase]>([])
        let program = try await installer.install(steam, into: env.bottle) { phase, _ in
            phases.withLock {
                if $0.last != phase {
                    $0.append(phase)
                }
            }
        }

        // Installer ran under wine with silent args, waiting for completion.
        // (The very first invocation is the pre-install bottle cleanup.)
        let invocation = try #require(env.runner.invocations.first {
            !$0.executable.hasSuffix("wineserver")
        })
        #expect(invocation.executable.hasSuffix("wine64"))
        #expect(invocation.arguments.prefix(3) == ["start", "/wait", "/unix"])
        #expect(invocation.arguments.last == "/S")
        #expect(invocation.arguments.contains { $0.hasSuffix("SteamSetup.exe") })

        // steam.cfg must NOT be pre-written — it would block the first
        // bootstrap update (missing steamui.dll).
        let cfg = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.cfg")
        #expect(!FileManager.default.fileExists(atPath: cfg.path))

        // Program registered, pinned, with verified launch flags.
        #expect(program.name == "Steam")
        #expect(program.pinned)
        #expect(program.arguments == ["-allosarches", "-noverifyfiles"])
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
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        try writeBootstrappedSteam(in: prefix)

        _ = try await installer.install(steam, into: env.bottle, progress: nil)
        let reloaded = try #require(await env.bottleStore.list().first)
        _ = try await installer.install(steam, into: reloaded, progress: nil)

        let final = try #require(await env.bottleStore.list().first)
        #expect(final.programs.count == 1)
    }

    @Test func switchesBottleToRunRuntimeAfterBootstrap() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let steam = try #require(InstallerCatalog.bundled().entries.first { $0.id == "steam" })
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        try writeBootstrappedSteam(in: prefix)

        #expect(env.bottle.runtimeID == "rt")
        _ = try await installer.install(steam, into: env.bottle, progress: nil)

        // The bottle now runs under the newer Wine, not the GPTK install runtime,
        // with the entry's performance tuning applied.
        let saved = try #require(await env.bottleStore.list().first)
        #expect(saved.runtimeID == "sikarugir-10.0-6-dxmt-0.80")
        #expect(saved.settings.sync == .msync)
        #expect(saved.settings.advertiseAVX == true)
    }

    @Test func migrateAppliesRunTuning() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: env.root),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let entry = try InstallerCatalog.Entry(
            id: "steam",
            name: "Steam",
            downloadURL: #require(URL(string: "https://example/SteamSetup.exe")),
            installerFileName: "SteamSetup.exe",
            silentArguments: ["/S"],
            installedWindowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            launchArguments: [],
            runRuntimeID: "run-rt",
            runTuning: .init(sync: .msync, advertiseAVX: true)
        )
        #expect(env.bottle.settings.sync == .esync)
        let migrated = try await installer.migrate(entry, in: env.bottle, progress: nil)
        #expect(migrated.runtimeID == "run-rt")
        #expect(migrated.settings.sync == .msync)
        #expect(migrated.settings.advertiseAVX == true)
        // The tuning must be persisted, not just returned.
        let saved = try #require(await env.bottleStore.list().first)
        #expect(saved.settings.sync == .msync)
        #expect(saved.settings.advertiseAVX == true)
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

@Suite("AppInstaller failure handling")
struct AppInstallerFailureTests {
    @Test func nonzeroInstallerExitAborts() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("bad-installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        // Runner reports a failed installer.
        let failing = FakeRunner(exitCode: 1)
        let launcher = WineLauncher(
            runtimeStore: env.runtimeStore,
            bottleStore: env.bottleStore,
            runner: failing,
            logsRoot: env.root.appendingPathComponent("logs"),
            defaultRuntimeID: "rt"
        )
        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: launcher,
            bottleStore: env.bottleStore
        )
        let steam = try #require(InstallerCatalog.bundled().entries.first { $0.id == "steam" })
        await #expect(throws: (any Error).self) {
            _ = try await installer.install(steam, into: env.bottle, progress: nil)
        }
        // No broken program left registered.
        let saved = try #require(await env.bottleStore.list().first)
        #expect(saved.programs.isEmpty)
    }
}

@Suite("Program icons")
struct ProgramIconTests {
    @Test func installerExtractsIconIntoBottle() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let fixture = env.root.appendingPathComponent("installer.exe")
        try Data("MZ".utf8).write(to: fixture)
        let steam = try #require(InstallerCatalog.bundled().entries.first { $0.id == "steam" })

        // Installer "produces" a real PE with an icon at the catalog path, plus
        // an already-downloaded steamui.dll so the bootstrap poll is skipped.
        let prefix = await env.bottleStore.prefixDirectory(of: env.bottle)
        try writeBootstrappedSteam(in: prefix, exe: FixturePE.build())

        let installer = AppInstaller(
            downloader: FakeDownloader(fixture: fixture),
            launcher: env.launcher(),
            bottleStore: env.bottleStore
        )
        let program = try await installer.install(steam, into: env.bottle, progress: nil)

        let bottleDir = await env.bottleStore.directory(of: env.bottle)
        let icon = ProgramIconStore.iconURL(programID: program.id, bottleDirectory: bottleDir)
        #expect(FileManager.default.fileExists(atPath: icon.path))
    }

    @Test func libraryExtractsIconAndDeleteRemovesIt() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let exe = env.root.appendingPathComponent("game.exe")
        try FixturePE.build().write(to: exe)

        let library = ProgramLibrary(bottleStore: env.bottleStore)
        let program = try await library.addProgram(exe: exe, name: nil, in: env.bottle)
        let bottleDir = await env.bottleStore.directory(of: env.bottle)
        let icon = ProgramIconStore.iconURL(programID: program.id, bottleDirectory: bottleDir)
        #expect(FileManager.default.fileExists(atPath: icon.path))

        let reloaded = try #require(await env.bottleStore.list().first)
        try await library.removeProgram(id: program.id, from: reloaded)
        #expect(!FileManager.default.fileExists(atPath: icon.path))
    }

    @Test func exeWithoutIconProducesNoFileButStillRegisters() async throws {
        let env = try await makeEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let exe = env.root.appendingPathComponent("plain.exe")
        try Data("MZ but not a real PE".utf8).write(to: exe)

        let library = ProgramLibrary(bottleStore: env.bottleStore)
        let program = try await library.addProgram(exe: exe, name: nil, in: env.bottle)
        let bottleDir = await env.bottleStore.directory(of: env.bottle)
        let icon = ProgramIconStore.iconURL(programID: program.id, bottleDirectory: bottleDir)
        #expect(!FileManager.default.fileExists(atPath: icon.path))
        let saved = try #require(await env.bottleStore.list().first)
        #expect(saved.programs.contains { $0.id == program.id })
    }
}
