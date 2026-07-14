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

/// Raised when a second install/migration is attempted while one is already in
/// flight — installs mutate a Wine prefix and share one progress slot, so only
/// one runs at a time.
public enum AppInstallError: LocalizedError {
    case anotherInstallInProgress
    /// The bottle's exclusive lease is held by another op (delete/install/launch),
    /// so a migration that must rewrite the prefix can't safely start.
    case bottleBusy

    public var errorDescription: String? {
        switch self {
        case .anotherInstallInProgress:
            String(localized: "Another install is in progress. Wait for it to finish, then try again.")
        case .bottleBusy:
            String(localized: "This bottle is busy with another operation. Wait for it to finish, then try again.")
        }
    }
}

/// The app's single observable source of truth. Views bind to it; every
/// effect goes through the injected system abstractions, so the whole state
/// machine is testable from SPM without a UI.
@MainActor
@Observable
public final class AppState {
    public internal(set) var bottles: [Bottle] = []
    public internal(set) var runtimeStatus: RuntimeStatus = .missing
    public internal(set) var runningIDs: Set<UUID> = []
    /// Programs launched but whose window hasn't appeared yet (cold start). The
    /// card shows a "Starting…" spinner for these until `markProgramWindowReady`.
    public internal(set) var launchingIDs: Set<UUID> = []
    /// Programs whose window has closed but whose process is still shutting down
    /// (Steam takes tens of seconds to fully exit). The card shows "Closing…"
    /// until the process exits and the button re-enables.
    public internal(set) var closingIDs: Set<UUID> = []
    /// Program currently being migrated to its run runtime on launch (so its card
    /// can show download progress instead of a plain "Running" state).
    public internal(set) var migratingProgramID: UUID?
    /// Bottles with a long-running install/migration writing into them.
    /// Deleting one mid-install would race the installer's writes, so delete
    /// is refused while a bottle is in this set.
    public internal(set) var busyBottleIDs: Set<UUID> = []
    /// Bottles whose prefix has a live wineserver — Windows programs are
    /// running in them right now, possibly launched by a previous app session
    /// (games survive GameMaster quitting by design). Refreshed on every
    /// refresh(); active bottles show as running and refuse deletion.
    public internal(set) var activeBottleIDs: Set<UUID> = []
    /// True while a new bottle's prefix is being initialized. wineboot takes
    /// seconds (more right after a runtime download, when Rosetta first
    /// translates the wine binaries) — the UI shows progress off this flag.
    public internal(set) var creatingBottle = false
    /// True while a shared-runtime maintenance op (GPTK import) holds the WRITER
    /// of `runtimeLease`. Surfaced for the UI and the entry guards
    /// (`blockedByRuntimeMaintenance`). The low-level safety invariant — no
    /// runtime replace overlapping a live Wine process — is enforced by the
    /// lease itself (readers vs. writer in `WineLauncher`), not by this flag.
    public var runtimeMaintenanceInProgress: Bool {
        runtimeLease.isWriterHeld
    }

    public var lastErrorMessage: String?
    public var selectedBottleID: UUID?

    public let catalog: InstallerCatalog
    public let gptkDetector: GPTKDetector

    let manifest: RuntimeManifest
    let runtimeStore: RuntimeStore
    let bottleStore: BottleStore
    let installer: RuntimeInstaller
    let importer: GPTKImporter
    let launcher: WineLauncher
    /// Single-writer/multi-reader lease over the shared runtime, shared with the
    /// off-actor `WineLauncher`: wine ops take readers, a GPTK import takes the
    /// writer. See `runtimeMaintenanceInProgress`.
    let runtimeLease: RuntimeLease
    /// Per-bottle single-writer/multi-reader lease: delete/install take the
    /// exclusive lease, launches take a shared one, so a bottle op can't
    /// penetrate another on the same bottle. The authority for that; the
    /// `Set<UUID>` flags below remain only for display.
    let bottleLeases = BottleLeases()
    let appInstaller: AppInstaller
    let programLibrary: ProgramLibrary
    let activityProbe: any PrefixActivityProbing
    let runner: any ProcessRunning
    public let logsRoot: URL

    // Monotonic tokens so a late progress callback (enqueued before an install
    // finished) can't overwrite the final state after completion.
    var runtimeInstallToken = 0
    var appInstallToken = 0
    var didRecoverRuntimeBackups = false

    /// Production entry point: real system implementations, app-support root.
    /// `hardwareProfileProvider` is supplied by the app layer (NSScreen-based)
    /// so GMApps stays free of AppKit.
    public convenience init(
        hardwareProfileProvider: @escaping @MainActor () -> HardwareProfile? = { nil }
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let runner = SubprocessRunner()
        self.init(
            root: support.appendingPathComponent("GameMaster", isDirectory: true),
            runner: runner,
            downloader: URLSessionDownloader(),
            mounter: HdiutilMounter(runner: runner),
            manifest: (try? RuntimeManifest.bundled())
                ?? RuntimeManifest(defaultRuntimeID: "", entries: []),
            hardwareProfileProvider: hardwareProfileProvider
        )
    }

    /// A nonzero exit inside this window after Play means the program died on
    /// startup (missing DLL, bad path) and is reported; after it, a nonzero
    /// code is a game quitting with junk status and is ignored. Injectable so
    /// tests don't wait out real seconds.
    let launchFailureWindowSeconds: TimeInterval

    /// How long a stop request waits for the bottle's wineserver to actually
    /// go quiet before concluding the kill didn't take. Injectable so tests
    /// don't wait out real seconds.
    let stopProbeTimeoutSeconds: TimeInterval

    /// Supplies the running Mac's display profile so new bottles can be seeded
    /// with hardware-tuned graphics defaults. Returns nil when no display is
    /// detectable (headless/tests) — then nothing is guessed. Injected by the
    /// app layer (NSScreen); left nil in unit tests unless a case needs it.
    let hardwareProfileProvider: @MainActor () -> HardwareProfile?

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
        activityProbe: any PrefixActivityProbing = WineServerProbe(),
        hardwareProfileProvider: @escaping @MainActor () -> HardwareProfile? = { nil }
    ) {
        self.manifest = manifest
        self.runner = runner
        self.launchFailureWindowSeconds = launchFailureWindowSeconds
        self.stopProbeTimeoutSeconds = stopProbeTimeoutSeconds
        self.activityProbe = activityProbe
        self.hardwareProfileProvider = hardwareProfileProvider
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
        let lease = RuntimeLease()
        runtimeLease = lease
        launcher = WineLauncher(
            runtimeStore: runtimeStore,
            bottleStore: bottleStore,
            runner: runner,
            logsRoot: logsRoot,
            defaultRuntimeID: manifest.defaultRuntimeID,
            // Shared lease: every wine op takes a reader, the import takes the
            // writer. Off-actor safe (RuntimeLease is lock-protected).
            lease: lease
        )
        appInstaller = AppInstaller(downloader: downloader, launcher: launcher, bottleStore: bottleStore)
        programLibrary = ProgramLibrary(bottleStore: bottleStore)
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
                    let runtimesDir = await runtimeStore.runtimesDirectory
                    try RuntimeInstaller.recoverOrphanedBackups(in: runtimesDir)
                    try RuntimeInstaller.recoverInterruptedGPTKImports(in: runtimesDir)
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
        guard !blockedByRuntimeMaintenance() else { return }
        guard let entry = manifest.defaultEntry else {
            lastErrorMessage = String(localized: "No runtime is configured for this build.")
            return
        }
        // Installing replaces the runtime directory, exactly like a GPTK import,
        // so take the WRITER (synchronously, before the first await). It's held
        // for the whole install, so no wine op runs against the half-replaced
        // runtime — and a second concurrent install is refused, because its
        // `blockedByRuntimeMaintenance()` guard above sees the writer held.
        guard runtimeLease.acquireWriter() else {
            lastErrorMessage = String(
                localized: "A program is running. Stop it before updating the graphics runtime."
            )
            return
        }
        defer { runtimeLease.releaseWriter() }
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
        // Importing replaces the shared runtime's libraries, so it needs a quiet
        // maintenance window: refuse while an install/runtime download is writing
        // or a program is running/launching in any bottle, where a live (or
        // later-spawned) process could load a mix of old and new components.
        // These checks are synchronous (no await) so nothing can slip in between
        // them and acquiring the lease just below.
        let runtimeInstalling = if case .installing = runtimeStatus {
            true
        } else {
            false
        }
        // `creatingBottle` matters too: a new bottle's wineboot loads libraries
        // from the shared runtime's wine/lib, and the bottle isn't in `bottles`
        // (so anyBottleActive can't see it) until after its boot succeeds.
        // `busyBottleIDs` covers a bottle install OR delete in flight (the
        // "delete-lock"): a delete's stopAll/removal runs after awaits, so
        // refusing here keeps the runtime from being replaced mid-delete.
        if runtimeMaintenanceInProgress || isInstalling || runtimeInstalling
            || creatingBottle || !busyBottleIDs.isEmpty {
            lastErrorMessage = String(
                localized: "An install is in progress. Wait for it to finish before updating the graphics runtime."
            )
            return
        }
        if !runningIDs.isEmpty || !launchingIDs.isEmpty {
            lastErrorMessage = String(
                localized: "A program is running. Stop it before updating the graphics runtime."
            )
            return
        }
        // Take the WRITER synchronously — before the awaited probe below — so no
        // wine op can start once we hold it. acquireWriter also fails atomically
        // if any wine op currently holds a READER (e.g. a retina regedit, which
        // sets no UI flag) — the check-then-await case the per-entry synchronous
        // flags can't cover. This is the low-level safety invariant.
        guard runtimeLease.acquireWriter() else {
            lastErrorMessage = String(
                localized: "A program is running. Stop it before updating the graphics runtime."
            )
            return
        }
        defer { runtimeLease.releaseWriter() }
        if await anyBottleActive() {
            lastErrorMessage = String(
                localized: "A program is running. Stop it before updating the graphics runtime."
            )
            return
        }
        do {
            let descriptor = try await operation()
            runtimeStatus = .ready(gptk: descriptor.gptk)
        } catch {
            report(error)
        }
    }

    // MARK: - Bottles

    public func createBottle(name: String) async {
        guard !blockedByRuntimeMaintenance() else { return }
        creatingBottle = true
        defer { creatingBottle = false }
        let bottle: Bottle
        do {
            bottle = try await bottleStore.create(name: name, runtimeID: manifest.defaultRuntimeID)
        } catch {
            report(error)
            return
        }
        do {
            var configured = bottle
            // Seed hardware-tuned graphics defaults before the first boot, so the
            // Retina registry the init writes already matches the recommendation.
            let runtimeID = configured.runtimeID ?? manifest.defaultRuntimeID
            if let hardware = hardwareProfileProvider(),
               let descriptor = try? await runtimeStore.descriptor(id: runtimeID) {
                configured.settings = PerformanceAdvisor.recommend(
                    for: hardware, runtime: descriptor, base: configured.settings
                )
                try await bottleStore.save(configured)
            }
            try await launcher.initializeBottle(configured)
            await refresh()
            selectedBottleID = configured.id
        } catch {
            // The bottle is already on disk but its first boot (or the pre-boot
            // save) failed. Roll it back so it can't resurface on the next
            // refresh as a broken ghost: stop any wineserver it spawned — scoped
            // to this new bottle's own prefix — then delete it.
            try? await launcher.stopAll(in: bottle)
            try? await bottleStore.delete(id: bottle.id)
            // Reflect disk truth. Check the bottle's directory directly, not the
            // listing: a partial delete could remove bottle.json but leave the
            // dir/prefix, which the listing skips — so `bottles` wouldn't show it
            // yet the leftover files are still there.
            await refresh()
            let bottleDirectory = await bottleStore.directory(of: bottle)
            if FileManager.default.fileExists(atPath: bottleDirectory.path) {
                // swiftlint:disable line_length
                lastErrorMessage = String(
                    localized: "Setting up the bottle failed, and its leftover files couldn’t be removed automatically. Delete the bottle manually."
                )
                // swiftlint:enable line_length
            } else {
                report(error)
            }
        }
    }

    public func deleteBottle(_ bottle: Bottle) async {
        // stopAll (wineserver -k) spawns wine against the shared runtime, and
        // its `try?` here would swallow the arbiter's refusal and delete anyway
        // — so refuse the whole delete up front while the runtime is replaced.
        guard !blockedByRuntimeMaintenance() else { return }
        guard !busyBottleIDs.contains(bottle.id) else {
            lastErrorMessage = String(
                localized: "This bottle is being installed into. Wait for the install to finish, then delete it."
            )
            return
        }
        // Take the bottle's EXCLUSIVE lease synchronously (before the first
        // await): it fails if a launch/install/another delete is in flight on
        // this bottle, so none of them can start once we hold it. This — not the
        // busyBottleIDs set below — is what keeps install/launch from racing the
        // prefix removal. Held for the whole delete.
        guard bottleLeases.acquireExclusive(bottle.id) else {
            lastErrorMessage = String(
                localized: "This bottle is busy with another operation. Wait for it to finish, then try again."
            )
            return
        }
        defer { bottleLeases.releaseExclusive(bottle.id) }
        busyBottleIDs.insert(bottle.id)
        defer { busyBottleIDs.remove(bottle.id) }
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

    // MARK: - Programs

    /// The install/migration currently writing into a bottle, tagged with that
    /// bottle's id so a sibling bottle's detail view can't show it. nil when
    /// nothing is installing.
    public internal(set) var activeInstall: ActiveInstall?

    public func installCatalogApp(id: String, into bottle: Bottle) async {
        guard let entry = catalog.entries.first(where: { $0.id == id }) else {
            lastErrorMessage = String(localized: "Unknown installer.")
            return
        }
        guard !blockedByRuntimeMaintenance() else { return }
        // One install/migration at a time: a second install — even into another
        // bottle — races prefix writes and clobbers the shared progress/token
        // and the delete-lock (busyBottleIDs). Refuse the concurrent start.
        guard activeInstall == nil else {
            lastErrorMessage = String(
                localized: "Another install is in progress. Wait for it to finish, then try again."
            )
            return
        }
        let bottleID = bottle.id
        // Exclusive lease (synchronous, before the first await): fails if this
        // bottle is being deleted or launched into, so an install can't race a
        // delete's prefix removal (or a launch). Held for the whole install.
        guard bottleLeases.acquireExclusive(bottleID) else {
            lastErrorMessage = String(
                localized: "This bottle is busy with another operation. Wait for it to finish, then try again."
            )
            return
        }
        defer { bottleLeases.releaseExclusive(bottleID) }
        appInstallToken += 1
        let token = appInstallToken
        activeInstall = ActiveInstall(bottleID: bottleID, phase: .downloading, fraction: 0)
        busyBottleIDs.insert(bottleID)
        defer { busyBottleIDs.remove(bottleID) }
        do {
            // The app may switch the bottle to a different run runtime (Steam
            // bootstraps under GPTK but runs under a newer Wine); fetch it first
            // so the switched bottle has a runtime to launch under.
            try await ensureRunRuntimeInstalled(for: entry, bottleID: bottleID, token: token)
            _ = try await appInstaller.install(entry, into: bottle) { [weak self] phase, fraction in
                Task { @MainActor [weak self] in
                    guard let self, appInstallToken == token else { return }
                    activeInstall = ActiveInstall(bottleID: bottleID, phase: phase, fraction: fraction)
                }
            }
        } catch {
            report(error)
        }
        appInstallToken += 1
        if activeInstall?.bottleID == bottleID {
            activeInstall = nil
        }
        await refresh()
    }

    /// Downloads the installer's `runRuntimeID` runtime if it isn't installed yet.
    /// No-op when the entry doesn't switch runtimes or the runtime is present.
    func ensureRunRuntimeInstalled(for entry: InstallerCatalog.Entry, bottleID: UUID, token: Int) async throws {
        guard let runID = entry.runRuntimeID,
              try await runtimeStore.descriptor(id: runID) == nil,
              let runtimeEntry = manifest.entries.first(where: { $0.id == runID })
        else { return }
        _ = try await installer.install(entry: runtimeEntry) { [weak self] _, fraction in
            Task { @MainActor [weak self] in
                guard let self, appInstallToken == token else { return }
                activeInstall = ActiveInstall(bottleID: bottleID, phase: .downloading, fraction: fraction)
            }
        }
    }
}
