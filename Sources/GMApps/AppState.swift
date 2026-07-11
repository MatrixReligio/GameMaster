import Foundation
import GMBottles
import GMLaunch
import GMModel
import GMRuntime
import GMSystem
import Observation

public enum RuntimeStatus: Sendable {
    case missing
    case installing(RuntimePhase, Double)
    case ready(gptk: GPTKStatus)
}

/// The app's single observable source of truth. Views bind to it; every
/// effect goes through the injected system abstractions, so the whole state
/// machine is testable from SPM without a UI.
@MainActor
@Observable
public final class AppState {
    public private(set) var bottles: [Bottle] = []
    public private(set) var runtimeStatus: RuntimeStatus = .missing
    public private(set) var runningIDs: Set<UUID> = []
    public var lastErrorMessage: String?
    public var selectedBottleID: UUID?

    public let catalog: InstallerCatalog
    public let gptkDetector: GPTKDetector

    private let manifest: RuntimeManifest
    private let runtimeStore: RuntimeStore
    private let bottleStore: BottleStore
    private let installer: RuntimeInstaller
    private let importer: GPTKImporter
    private let launcher: WineLauncher
    private let appInstaller: AppInstaller
    private let programLibrary: ProgramLibrary
    private let tracker = RunningTracker()
    private let runner: any ProcessRunning
    public let logsRoot: URL

    // Monotonic tokens so a late progress callback (enqueued before an install
    // finished) can't overwrite the final state after completion.
    private var runtimeInstallToken = 0
    private var appInstallToken = 0

    /// Production entry point: real system implementations, app-support root.
    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let runner = SubprocessRunner()
        self.init(
            root: support.appendingPathComponent("GameMaster", isDirectory: true),
            runner: runner,
            downloader: URLSessionDownloader(),
            mounter: HdiutilMounter(runner: runner),
            manifest: (try? RuntimeManifest.bundled())
                ?? RuntimeManifest(defaultRuntimeID: "", entries: [])
        )
    }

    /// `runner` launches wine; `systemToolRunner` (defaults to `runner`)
    /// launches tar/ditto/xattr — tests fake wine while keeping real tools.
    public init(
        root: URL,
        runner: any ProcessRunning,
        downloader: any Downloading,
        mounter: any DiskImageMounting,
        manifest: RuntimeManifest,
        detector: GPTKDetector = GPTKDetector(),
        systemToolRunner: (any ProcessRunning)? = nil
    ) {
        self.manifest = manifest
        self.runner = runner
        let toolRunner = systemToolRunner ?? runner
        gptkDetector = detector
        catalog = (try? InstallerCatalog.bundled()) ?? InstallerCatalog(entries: [])
        logsRoot = root.appendingPathComponent("logs", isDirectory: true)
        runtimeStore = RuntimeStore(root: root)
        bottleStore = BottleStore(root: root)
        installer = RuntimeInstaller(store: runtimeStore, downloader: downloader, runner: toolRunner)
        importer = GPTKImporter(store: runtimeStore, mounter: mounter, runner: toolRunner)
        launcher = WineLauncher(
            runtimeStore: runtimeStore,
            bottleStore: bottleStore,
            runner: runner,
            logsRoot: logsRoot,
            defaultRuntimeID: manifest.defaultRuntimeID
        )
        appInstaller = AppInstaller(downloader: downloader, launcher: launcher, bottleStore: bottleStore)
        programLibrary = ProgramLibrary(bottleStore: bottleStore)
    }

    public var needsOnboarding: Bool {
        if case .ready = runtimeStatus {
            return false
        }
        return true
    }

    public var defaultRuntimeID: String {
        manifest.defaultRuntimeID
    }

    // MARK: - Lifecycle

    public func refresh() async {
        do {
            bottles = try await bottleStore.list()
            if case .installing = runtimeStatus {
                // Keep showing progress; installer updates status itself.
            } else if let descriptor = try await runtimeStore.descriptor(id: manifest.defaultRuntimeID) {
                runtimeStatus = .ready(gptk: descriptor.gptk)
            } else {
                runtimeStatus = .missing
            }
        } catch {
            report(error)
        }
    }

    public func installDefaultRuntime() async {
        guard let entry = manifest.defaultEntry else {
            lastErrorMessage = String(localized: "No runtime is configured for this build.")
            return
        }
        runtimeInstallToken += 1
        let token = runtimeInstallToken
        runtimeStatus = .installing(.downloading, 0)
        do {
            let descriptor = try await installer.install(entry: entry) { [weak self] phase, fraction in
                Task { @MainActor [weak self] in
                    guard let self, runtimeInstallToken == token else { return }
                    runtimeStatus = .installing(phase, fraction)
                }
            }
            // Invalidate any still-queued progress callbacks before settling.
            runtimeInstallToken += 1
            runtimeStatus = .ready(gptk: descriptor.gptk)
        } catch {
            runtimeInstallToken += 1
            runtimeStatus = .missing
            report(error)
        }
        await refresh()
    }

    public func importGPTK(dmg: URL) async {
        await importGPTK { try await self.importer.importGPTK(dmg: dmg, into: self.manifest.defaultRuntimeID) }
    }

    public func importGPTK(mountedVolume: URL) async {
        await importGPTK {
            try await self.importer.importGPTK(
                mountedVolume: mountedVolume,
                into: self.manifest.defaultRuntimeID
            )
        }
    }

    private func importGPTK(_ operation: () async throws -> RuntimeDescriptor) async {
        do {
            let descriptor = try await operation()
            runtimeStatus = .ready(gptk: descriptor.gptk)
        } catch {
            report(error)
        }
    }

    // MARK: - Bottles

    public func createBottle(name: String) async {
        do {
            let bottle = try await bottleStore.create(name: name, runtimeID: manifest.defaultRuntimeID)
            try await launcher.initializeBottle(bottle)
            await refresh()
            selectedBottleID = bottle.id
        } catch {
            report(error)
        }
    }

    public func deleteBottle(_ bottle: Bottle) async {
        do {
            try? await launcher.stopAll(in: bottle)
            try await bottleStore.delete(id: bottle.id)
            await refresh()
        } catch {
            report(error)
        }
    }

    public func updateBottle(_ bottle: Bottle) async {
        do {
            try await bottleStore.save(bottle)
            await refresh()
        } catch {
            report(error)
        }
    }

    // MARK: - Programs

    public private(set) var installProgress: (phase: InstallPhase, fraction: Double)?

    public func installCatalogApp(id: String, into bottle: Bottle) async {
        guard let entry = catalog.entries.first(where: { $0.id == id }) else {
            lastErrorMessage = String(localized: "Unknown installer.")
            return
        }
        appInstallToken += 1
        let token = appInstallToken
        installProgress = (.downloading, 0)
        do {
            _ = try await appInstaller.install(entry, into: bottle) { [weak self] phase, fraction in
                Task { @MainActor [weak self] in
                    guard let self, appInstallToken == token else { return }
                    installProgress = (phase, fraction)
                }
            }
        } catch {
            report(error)
        }
        appInstallToken += 1
        installProgress = nil
        await refresh()
    }

    public func addProgram(exe: URL, in bottle: Bottle) async {
        do {
            _ = try await programLibrary.addProgram(exe: exe, name: nil, in: bottle)
            await refresh()
        } catch {
            report(error)
        }
    }

    public func removeProgram(id: UUID, from bottle: Bottle) async {
        do {
            try await programLibrary.removeProgram(id: id, from: bottle)
            await refresh()
        } catch {
            report(error)
        }
    }

    public func launch(program: Program, in bottle: Bottle) async {
        runningIDs.insert(program.id)
        do {
            _ = try await launcher.launch(program, in: bottle)
        } catch {
            report(error)
        }
        runningIDs.remove(program.id)
    }

    public func runExe(_ exe: URL, in bottle: Bottle) async {
        do {
            _ = try await launcher.run(exe: exe, arguments: [], in: bottle)
        } catch {
            report(error)
        }
    }

    public func stopAll(in bottle: Bottle) async {
        do {
            try await launcher.stopAll(in: bottle)
        } catch {
            report(error)
        }
        // Only this bottle's programs were killed — leave other bottles' state.
        for program in bottle.programs {
            runningIDs.remove(program.id)
        }
    }

    // MARK: - Environment checks

    /// Rosetta 2 must be installed for the x86_64 wine runtime.
    public func rosettaInstalled() async -> Bool {
        let result = try? await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-q", "oahd"],
            environment: nil,
            currentDirectory: nil,
            outputLine: nil
        )
        return result?.exitCode == 0
    }

    private func report(_ error: any Error) {
        lastErrorMessage = error.localizedDescription
    }
}
