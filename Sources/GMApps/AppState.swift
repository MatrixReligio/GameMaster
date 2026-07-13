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
    /// Programs launched but whose window hasn't appeared yet (cold start). The
    /// card shows a "Starting…" spinner for these until `markProgramWindowReady`.
    public private(set) var launchingIDs: Set<UUID> = []
    /// Programs whose window has closed but whose process is still shutting down
    /// (Steam takes tens of seconds to fully exit). The card shows "Closing…"
    /// until the process exits and the button re-enables.
    public private(set) var closingIDs: Set<UUID> = []
    /// Program currently being migrated to its run runtime on launch (so its card
    /// can show download progress instead of a plain "Running" state).
    public private(set) var migratingProgramID: UUID?
    /// Bottles with a long-running install/migration writing into them.
    /// Deleting one mid-install would race the installer's writes, so delete
    /// is refused while a bottle is in this set.
    public private(set) var busyBottleIDs: Set<UUID> = []
    /// Bottles whose prefix has a live wineserver — Windows programs are
    /// running in them right now, possibly launched by a previous app session
    /// (games survive GameMaster quitting by design). Refreshed on every
    /// refresh(); active bottles show as running and refuse deletion.
    public private(set) var activeBottleIDs: Set<UUID> = []
    /// True while a new bottle's prefix is being initialized. wineboot takes
    /// seconds (more right after a runtime download, when Rosetta first
    /// translates the wine binaries) — the UI shows progress off this flag.
    public private(set) var creatingBottle = false
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
    private let activityProbe: any PrefixActivityProbing
    private let runner: any ProcessRunning
    public let logsRoot: URL

    // Monotonic tokens so a late progress callback (enqueued before an install
    // finished) can't overwrite the final state after completion.
    private var runtimeInstallToken = 0
    private var appInstallToken = 0
    private var didRecoverRuntimeBackups = false

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

    /// A nonzero exit inside this window after Play means the program died on
    /// startup (missing DLL, bad path) and is reported; after it, a nonzero
    /// code is a game quitting with junk status and is ignored. Injectable so
    /// tests don't wait out real seconds.
    private let launchFailureWindowSeconds: TimeInterval

    /// How long a stop request waits for the bottle's wineserver to actually
    /// go quiet before concluding the kill didn't take. Injectable so tests
    /// don't wait out real seconds.
    private let stopProbeTimeoutSeconds: TimeInterval

    /// `runner` launches wine; `systemToolRunner` (defaults to `runner`)
    /// launches tar/ditto/xattr — tests fake wine while keeping real tools.
    public init(
        root: URL,
        runner: any ProcessRunning,
        downloader: any Downloading,
        mounter: any DiskImageMounting,
        manifest: RuntimeManifest,
        detector: GPTKDetector = GPTKDetector(),
        systemToolRunner: (any ProcessRunning)? = nil,
        launchFailureWindowSeconds: TimeInterval = 10,
        stopProbeTimeoutSeconds: TimeInterval = 30,
        activityProbe: any PrefixActivityProbing = WineServerProbe()
    ) {
        self.manifest = manifest
        self.runner = runner
        self.launchFailureWindowSeconds = launchFailureWindowSeconds
        self.stopProbeTimeoutSeconds = stopProbeTimeoutSeconds
        self.activityProbe = activityProbe
        let toolRunner = systemToolRunner ?? runner
        gptkDetector = detector
        catalog = (try? InstallerCatalog.bundled()) ?? InstallerCatalog(entries: [])
        logsRoot = root.appendingPathComponent("logs", isDirectory: true)
        runtimeStore = RuntimeStore(root: root)
        bottleStore = BottleStore(root: root)
        installer = RuntimeInstaller(store: runtimeStore, downloader: downloader, runner: toolRunner)
        importer = GPTKImporter(
            store: runtimeStore,
            mounter: mounter,
            runner: toolRunner,
            verifier: CodesignVerifier(runner: toolRunner)
        )
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
            // Once, before any install can create fresh backups: restore
            // runtime directories a crash left renamed-aside mid-replace.
            // Best-effort: the "done" flag is set only AFTER success (so a
            // transient failure retries next refresh instead of being skipped
            // forever), and a failure is reported without aborting the rest of
            // refresh (bottles + runtime status must still load).
            if !didRecoverRuntimeBackups {
                do {
                    try await RuntimeInstaller.recoverOrphanedBackups(in: runtimeStore.runtimesDirectory)
                    didRecoverRuntimeBackups = true
                } catch {
                    report(error)
                }
            }
            let listing = try await bottleStore.listing()
            bottles = listing.bottles
            // Rediscover bottles whose wineserver is still alive (programs
            // launched by a previous app session keep running by design).
            var active: Set<UUID> = []
            for bottle in listing.bottles {
                let prefix = await bottleStore.prefixDirectory(of: bottle)
                if activityProbe.isActive(prefix: prefix) {
                    active.insert(bottle.id)
                }
            }
            activeBottleIDs = active
            if !listing.corruptFiles.isEmpty {
                lastErrorMessage = String(
                    // swiftlint:disable:next line_length
                    localized: "Some bottles have unreadable metadata and are hidden. Their files remain on disk untouched."
                )
            }
            let runtimeListing = try await runtimeStore.listing()
            if !runtimeListing.corruptFiles.isEmpty {
                lastErrorMessage = String(
                    // swiftlint:disable:next line_length
                    localized: "Some runtimes have unreadable metadata and are hidden. Their files remain on disk untouched."
                )
            }
            if case .installing = runtimeStatus {
                // Keep showing progress; installer updates status itself.
            } else if let descriptor = runtimeListing.runtimes.first(where: { $0.id == manifest.defaultRuntimeID }) {
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
        creatingBottle = true
        defer { creatingBottle = false }
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
        guard !busyBottleIDs.contains(bottle.id) else {
            lastErrorMessage = String(
                localized: "This bottle is being installed into. Wait for the install to finish, then delete it."
            )
            return
        }
        // Probe live (not the cached set): the user may have just stopped the
        // game, or started one this very second — deletion needs the truth now.
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        guard !activityProbe.isActive(prefix: prefix) else {
            activeBottleIDs.insert(bottle.id)
            lastErrorMessage = String(
                localized: "Windows programs are still running in this bottle. Stop them first, then delete it."
            )
            return
        }
        do {
            try? await launcher.stopAll(in: bottle)
            try await bottleStore.delete(id: bottle.id)
            await refresh()
        } catch {
            report(error)
        }
    }

    /// Saves the settings sheet's fields — name and settings ONLY — on the
    /// bottle's current state, so a sheet left open through an install can't
    /// clobber the programs/runtime the install registered.
    public func updateBottle(id: UUID, name: String, settings: BottleSettings) async {
        do {
            // Retina lives in the Wine registry. Registry first, JSON second:
            // committing JSON before a failing regedit would make the next
            // same-value save read as "unchanged" and never retry, leaving
            // the two permanently split. The change check uses the bottle's
            // current ON-DISK value for the same reason.
            let current = try await bottleStore.list().first { $0.id == id }
            if var staged = current, staged.settings.retinaMode != settings.retinaMode {
                staged.name = name
                staged.settings = settings
                try await launcher.applyRetinaRegistry(in: staged)
            }
            try await bottleStore.update(id: id) { bottle in
                bottle.name = name
                bottle.settings = settings
            }
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
        busyBottleIDs.insert(bottle.id)
        defer { busyBottleIDs.remove(bottle.id) }
        do {
            // The app may switch the bottle to a different run runtime (Steam
            // bootstraps under GPTK but runs under a newer Wine); fetch it first
            // so the switched bottle has a runtime to launch under.
            try await ensureRunRuntimeInstalled(for: entry, token: token)
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

    /// Downloads the installer's `runRuntimeID` runtime if it isn't installed yet.
    /// No-op when the entry doesn't switch runtimes or the runtime is present.
    private func ensureRunRuntimeInstalled(for entry: InstallerCatalog.Entry, token: Int) async throws {
        guard let runID = entry.runRuntimeID,
              try await runtimeStore.descriptor(id: runID) == nil,
              let runtimeEntry = manifest.entries.first(where: { $0.id == runID })
        else { return }
        _ = try await installer.install(entry: runtimeEntry) { [weak self] _, fraction in
            Task { @MainActor [weak self] in
                guard let self, appInstallToken == token else { return }
                installProgress = (.downloading, fraction)
            }
        }
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

    /// Icon for a program card. Extracts lazily for programs registered
    /// before icon support (or after Steam's bootstrap replaced the exe).
    public func iconURL(for program: Program, in bottle: Bottle) async -> URL? {
        let bottleDirectory = await bottleStore.directory(of: bottle)
        let url = ProgramIconStore.iconURL(programID: program.id, bottleDirectory: bottleDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        let exe = WindowsPath.toUnix(program.windowsPath, prefix: prefix)
        return ProgramIconStore.extractAndStore(
            exe: exe,
            programID: program.id,
            bottleDirectory: bottleDirectory
        )
    }
}

// MARK: - Launching, stopping, and runtime queries

public extension AppState {
    /// Whether the program should present as running: either this session
    /// launched it, or the bottle's wineserver is alive from a previous app
    /// session (games survive GameMaster quitting by design) — after a
    /// relaunch the per-program IDs are gone, and offering Play on a live
    /// bottle invites a second instance.
    func isProgramRunning(_ program: Program, in bottle: Bottle) -> Bool {
        runningIDs.contains(program.id) || activeBottleIDs.contains(bottle.id)
    }

    func launch(program: Program, in bottle: Bottle) async {
        runningIDs.insert(program.id)
        // "Launching" spans the click until the program's window appears (or a
        // safety timeout) — Steam's cold start under Wine takes tens of seconds,
        // and the UI shows a spinner during it. The window is reported by the
        // app layer via `markProgramWindowReady`; this timeout keeps the spinner
        // from spinning forever if detection misses.
        launchingIDs.insert(program.id)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90))
            self?.launchingIDs.remove(program.id)
        }
        do {
            let bottle = try await migrateSteamBottleIfNeeded(program: program, in: bottle)
            await ensureWebHelperWrapper(for: program, in: bottle)
            // `start /wait` returns only when the program's process fully exits —
            // for Steam that's after its (slow) shutdown, which the "Closing…"
            // state covers.
            let launchedAt = Date()
            let result = try await launcher.launch(program, in: bottle)
            // Died on startup → tell the user. A nonzero exit after a real
            // session is a game quitting with a junk status code — ignore it.
            if result.exitCode != 0,
               Date().timeIntervalSince(launchedAt) < launchFailureWindowSeconds {
                report(LaunchError.commandFailed(command: program.name, exitCode: result.exitCode))
            }
        } catch {
            report(error)
        }
        runningIDs.remove(program.id)
        launchingIDs.remove(program.id)
        closingIDs.remove(program.id)
    }

    /// Called by the app layer once the program's window is visible, to end the
    /// "launching" spinner. No-op if already ended (timeout or exit).
    func markProgramWindowReady(_ programID: UUID) {
        launchingIDs.remove(programID)
    }

    /// Called by the app layer when the program's window has closed while its
    /// process is still exiting, so the card can show "Closing…" until the
    /// `launch` call returns.
    func markProgramClosing(_ programID: UUID) {
        guard runningIDs.contains(programID) else { return }
        launchingIDs.remove(programID)
        closingIDs.insert(programID)
    }

    /// Upgrades a Steam bottle created before the dual-runtime fix: downloads the
    /// run runtime (with progress), bootstraps/wraps, and switches the bottle to
    /// it — so launching an old GPTK-pinned Steam no longer loops. No-op once the
    /// bottle is already on its run runtime. Returns the bottle to launch.
    private func migrateSteamBottleIfNeeded(program: Program, in bottle: Bottle) async throws -> Bottle {
        guard let entry = catalog.entries.first(where: {
            $0.installedWindowsPath == program.windowsPath && $0.runRuntimeID != nil
        }), let runID = entry.runRuntimeID, bottle.runtimeID != runID else {
            return bottle
        }
        appInstallToken += 1
        let token = appInstallToken
        migratingProgramID = program.id
        installProgress = (.downloading, 0)
        busyBottleIDs.insert(bottle.id)
        defer {
            appInstallToken += 1
            migratingProgramID = nil
            installProgress = nil
            busyBottleIDs.remove(bottle.id)
        }
        try await ensureRunRuntimeInstalled(for: entry, token: token)
        let migrated = try await appInstaller.migrate(entry, in: bottle) { [weak self] phase, fraction in
            Task { @MainActor [weak self] in
                guard let self, appInstallToken == token else { return }
                installProgress = (phase, fraction)
            }
        }
        bottles = try await bottleStore.list()
        return migrated
    }

    /// Repairs Steam's CEF web-helper wrapper and service stub before launch: a
    /// Steam self-update can overwrite them with the stock binaries, bringing
    /// back the black UI and the "Steam Service Error" dialog. Idempotent and a
    /// no-op for programs without those specs.
    private func ensureWebHelperWrapper(for program: Program, in bottle: Bottle) async {
        guard let entry = catalog.entries.first(where: {
            $0.installedWindowsPath == program.windowsPath
                && ($0.webhelperWrapper != nil || $0.serviceStub != nil)
        }) else { return }
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        try? AppInstaller.applySteamBinaryFixups(entry: entry, prefix: prefix)
    }

    /// Gracefully stops a running program. Catalog programs with
    /// `shutdownArguments` get their own clean-exit command routed through the
    /// running instance (Steam's `-shutdown` saves state and syncs the cloud);
    /// everything else receives WM_CLOSE via taskkill, the same as clicking
    /// the window's close button. The card shows "Closing…" until the
    /// program's `launch` call returns.
    func stopProgram(_ program: Program, in bottle: Bottle) async {
        markProgramClosing(program.id)
        do {
            if let entry = catalog.entries.first(where: {
                $0.installedWindowsPath == program.windowsPath && $0.shutdownArguments != nil
            }), let arguments = entry.shutdownArguments {
                let prefix = await bottleStore.prefixDirectory(of: bottle)
                let exe = WindowsPath.toUnix(program.windowsPath, prefix: prefix)
                _ = try await launcher.run(exe: exe, arguments: arguments, in: bottle, wait: false)
            } else {
                let imageName = program.windowsPath
                    .split(separator: "\\").last.map(String.init) ?? program.windowsPath
                try await launcher.taskkill(imageName: imageName, in: bottle)
            }
        } catch {
            report(error)
        }
        await settleStoppedBottle(bottle)
    }

    func runExe(_ exe: URL, in bottle: Bottle) async {
        do {
            // Fire-and-forget: the result is wine's `start` helper, which
            // exits nonzero exactly when the program could not be launched.
            let result = try await launcher.run(exe: exe, arguments: [], in: bottle)
            if result.exitCode != 0 {
                report(LaunchError.commandFailed(
                    command: exe.lastPathComponent,
                    exitCode: result.exitCode
                ))
            }
        } catch {
            report(error)
        }
    }

    func stopAll(in bottle: Bottle) async {
        do {
            try await launcher.stopAll(in: bottle)
        } catch {
            report(error)
        }
        await settleStoppedBottle(bottle)
    }

    /// After a stop request, believe the probe — not the request: waits for
    /// the bottle's wineserver to go quiet (bounded) and only then clears
    /// its running state. If the kill didn't take, the bottle keeps showing
    /// as running instead of optimistically flipping to idle.
    private func settleStoppedBottle(_ bottle: Bottle) async {
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        let deadline = Date().addingTimeInterval(stopProbeTimeoutSeconds)
        while activityProbe.isActive(prefix: prefix), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if activityProbe.isActive(prefix: prefix) {
            activeBottleIDs.insert(bottle.id)
            // The stop didn't take (the program is ignoring WM_CLOSE — a save
            // dialog, Steam updating). Clear the transient "Closing…" flag so
            // the cards revert to Running + Stop instead of a spinner with no
            // button, and tell the user the programs are still alive.
            for program in bottle.programs {
                closingIDs.remove(program.id)
            }
            lastErrorMessage = String(
                // swiftlint:disable:next line_length
                localized: "Some programs are still running and could not be stopped. They may be waiting for you to confirm something in their window — handle it and try again, or use Force Stop All."
            )
        } else {
            activeBottleIDs.remove(bottle.id)
            // Only this bottle's programs stopped — leave other bottles' state.
            for program in bottle.programs {
                runningIDs.remove(program.id)
                closingIDs.remove(program.id)
            }
        }
    }

    /// Whether the bottle's runtime translates D3D via DXMT builtins. DXMT is
    /// installed INTO wine (replacing d3d11/dxgi), so unlike D3DMetal there is
    /// no environment switch that turns it off — the settings sheet hides the
    /// "Off" choice for these bottles instead of offering a dead toggle.
    func bottleUsesDXMTRuntime(_ bottle: Bottle) async -> Bool {
        let id = bottle.runtimeID ?? manifest.defaultRuntimeID
        guard let descriptor = try? await runtimeStore.descriptor(id: id),
              case .installed = descriptor.dxmt
        else {
            return false
        }
        return true
    }

    // MARK: - Environment checks

    /// Rosetta 2 must be installed for the x86_64 wine runtime.
    func rosettaInstalled() async -> Bool {
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
