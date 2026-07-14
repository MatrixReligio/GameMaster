import Foundation
import GMBottles
import GMLaunch
import GMModel
import GMRuntime
import GMSystem

// MARK: - Launching, stopping, and runtime queries

public extension AppState {
    /// Saves the settings sheet's fields — name and settings ONLY — on the
    /// bottle's current state, so a sheet left open through an install can't
    /// clobber the programs/runtime the install registered.
    func updateBottle(id: UUID, name: String, settings: BottleSettings) async {
        // A retina change re-applies the Wine registry (a wine process), and
        // even a name-only save shouldn't land while the runtime is mid-replace
        // — refuse the whole edit for one consistent maintenance window.
        guard !blockedByRuntimeMaintenance() else { return }
        // Shared bottle lease: a settings save is compatible with a running game
        // (both readers) but must be excluded from a delete/install (writer).
        guard bottleLeases.acquireShared(id) else {
            lastErrorMessage = String(
                localized: "This bottle is busy with another operation. Wait for it to finish, then try again."
            )
            return
        }
        defer { bottleLeases.releaseShared(id) }
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

    func removeProgram(id: UUID, from bottle: Bottle) async {
        do {
            try await programLibrary.removeProgram(id: id, from: bottle)
            await refresh()
        } catch {
            report(error)
        }
    }

    /// Whether the program should present as running: either this session
    /// launched it, or the bottle's wineserver is alive from a previous app
    /// session (games survive GameMaster quitting by design) — after a
    /// relaunch the per-program IDs are gone, and offering Play on a live
    /// bottle invites a second instance.
    func isProgramRunning(_ program: Program, in bottle: Bottle) -> Bool {
        runningIDs.contains(program.id) || activeBottleIDs.contains(bottle.id)
    }

    func launch(program: Program, in bottle: Bottle) async {
        guard !blockedByRuntimeMaintenance() else { return }
        // Refuse a second launch of a program already starting/running. The UI
        // hides Play once it's launching, but a second window shares this same
        // AppState, so two Play clicks could otherwise run the Steam binary
        // fixups on one prefix concurrently. These inserts are synchronous
        // (before the first await — the migration below), so the re-entrant call
        // sees them and bails; a function-scope defer clears them on every path.
        guard !runningIDs.contains(program.id), !launchingIDs.contains(program.id) else { return }
        runningIDs.insert(program.id)
        // "Launching" spans the click until the program's window appears (or a
        // safety timeout) — Steam's cold start under Wine takes tens of seconds,
        // and the UI shows a spinner during it. The window is reported by the
        // app layer via `markProgramWindowReady`; this timeout keeps the spinner
        // from spinning forever if detection misses.
        launchingIDs.insert(program.id)
        defer {
            runningIDs.remove(program.id)
            launchingIDs.remove(program.id)
            closingIDs.remove(program.id)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(90))
            self?.launchingIDs.remove(program.id)
        }
        // A Steam bottle created before the dual-runtime split needs a one-time
        // migration that REWRITES the prefix. Run it FIRST, under the bottle's
        // EXCLUSIVE lease (taken inside migrateSteamBottleIfNeeded), before the
        // shared launch below — under the shared lease a concurrent launch/runExe
        // on this bottle could touch the prefix mid-migration.
        let target: Bottle
        do {
            target = try await migrateSteamBottleIfNeeded(program: program, in: bottle)
        } catch {
            report(error)
            return
        }
        // Shared lease on the bottle (synchronous), held for the whole session:
        // fails while a delete/install/migration holds the bottle exclusively, so
        // a launch can't enter a prefix being removed or written; and while held,
        // a delete/install is refused.
        guard bottleLeases.acquireShared(target.id) else {
            lastErrorMessage = String(
                localized: "This bottle is busy with another operation. Wait for it to finish, then try again."
            )
            return
        }
        defer { bottleLeases.releaseShared(target.id) }
        do {
            try await ensureWebHelperWrapper(for: program, in: target)
            // `start /wait` returns only when the program's process fully exits —
            // for Steam that's after its (slow) shutdown, which the "Closing…"
            // state covers.
            let launchedAt = Date()
            let result = try await launcher.launch(program, in: target)
            // Died on startup → tell the user. A nonzero exit after a real
            // session is a game quitting with a junk status code — ignore it.
            if result.exitCode != 0,
               Date().timeIntervalSince(launchedAt) < launchFailureWindowSeconds {
                report(LaunchError.commandFailed(command: program.name, exitCode: result.exitCode))
            }
        } catch {
            report(error)
        }
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
            return bottle // no migration needed → no lease taken
        }
        // One install/migration at a time (see installCatalogApp): don't race a
        // concurrent install's prefix writes and shared progress slot.
        guard activeInstall == nil else { throw AppInstallError.anotherInstallInProgress }
        // The migration REWRITES the prefix (download run runtime, bootstrap,
        // switch runtime) — the same class of mutation as an install, so take the
        // bottle EXCLUSIVELY, not the shared launch lease. Synchronous acquire
        // before the first await; a concurrent launch/runExe on this bottle is
        // refused while it's held, and this refuses if one is already running.
        guard bottleLeases.acquireExclusive(bottle.id) else {
            throw AppInstallError.bottleBusy
        }
        defer { bottleLeases.releaseExclusive(bottle.id) }
        let bottleID = bottle.id
        appInstallToken += 1
        let token = appInstallToken
        migratingProgramID = program.id
        activeInstall = ActiveInstall(bottleID: bottleID, phase: .downloading, fraction: 0)
        busyBottleIDs.insert(bottleID)
        defer {
            appInstallToken += 1
            migratingProgramID = nil
            if activeInstall?.bottleID == bottleID {
                activeInstall = nil
            }
            busyBottleIDs.remove(bottleID)
        }
        try await ensureRunRuntimeInstalled(for: entry, bottleID: bottleID, token: token)
        let migrated = try await appInstaller.migrate(entry, in: bottle) { [weak self] phase, fraction in
            Task { @MainActor [weak self] in
                guard let self, appInstallToken == token else { return }
                activeInstall = ActiveInstall(bottleID: bottleID, phase: phase, fraction: fraction)
            }
        }
        bottles = try await bottleStore.list()
        return migrated
    }

    /// Repairs Steam's CEF web-helper wrapper and service stub before launch: a
    /// Steam self-update can overwrite them with the stock binaries, bringing
    /// back the black UI and the "Steam Service Error" dialog. Idempotent and a
    /// no-op for programs without those specs.
    private func ensureWebHelperWrapper(for program: Program, in bottle: Bottle) async throws {
        guard let entry = catalog.entries.first(where: {
            $0.installedWindowsPath == program.windowsPath
                && ($0.webhelperWrapper != nil || $0.serviceStub != nil)
        }) else { return }
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        // Propagate: without the CEF wrapper Steam's UI renders black, so a
        // failed fixup is launch-critical — surface it as an actionable error
        // rather than launching into an unusable client. Stop/control paths
        // don't run this, so they stay independent of graphics fixups.
        try AppInstaller.applySteamBinaryFixups(entry: entry, prefix: prefix)
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
                // A control command, not a launch: never run MetalFX prep, so a
                // broken MetalFX file can't stop us from stopping the program.
                _ = try await launcher.runControlCommand(exe: exe, arguments: arguments, in: bottle)
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

    /// Adds a dropped exe to the library and launches it through the running
    /// state machine, so the new card shows Starting/Running instead of Play on
    /// an already-running program (a second click would start a duplicate).
    /// Unlike `runExe`, the launch is tracked, not fire-and-forget.
    func addProgramAndLaunch(exe: URL, in bottle: Bottle) async {
        // Refuse BEFORE registering: the launch below would be refused during
        // maintenance anyway, leaving the program added-but-unlaunched — and
        // re-dropping the same exe would then duplicate it. Guard up front.
        guard !blockedByRuntimeMaintenance() else { return }
        // Register under the bottle's shared lease, RELEASED before the launch:
        // the nested launch takes its own lease, and if the dropped program needs
        // a Steam migration that lease is EXCLUSIVE — which a still-held shared
        // reader here would block, self-refusing the launch every time.
        guard let program = await registerDroppedProgram(exe: exe, in: bottle) else { return }
        await launch(program: program, in: bottle)
    }

    /// Adds a dropped exe to `bottle` under the bottle's SHARED lease (excludes a
    /// concurrent delete during `addProgram`'s mutation), refreshes, and returns
    /// the new program. The lease is released before this returns so the launch
    /// can take its own. nil on refusal/failure.
    private func registerDroppedProgram(exe: URL, in bottle: Bottle) async -> Program? {
        guard bottleLeases.acquireShared(bottle.id) else {
            lastErrorMessage = String(
                localized: "This bottle is busy with another operation. Wait for it to finish, then try again."
            )
            return nil
        }
        defer { bottleLeases.releaseShared(bottle.id) }
        // `addProgram` is an actor hop, so mark a launch in flight synchronously
        // (before that await) so a GPTK import can't raise the lease during the
        // register window. Synthetic id (not a program's) so it lights up no
        // card; mirrors runExe. The marker hands off with no await gap to the
        // launch's own program-id markers.
        let launchMarker = UUID()
        launchingIDs.insert(launchMarker)
        defer { launchingIDs.remove(launchMarker) }
        do {
            let program = try await programLibrary.addProgram(exe: exe, name: nil, in: bottle)
            await refresh()
            return program
        } catch {
            report(error)
            return nil
        }
    }

    func runExe(_ exe: URL, in bottle: Bottle) async {
        guard !blockedByRuntimeMaintenance() else { return }
        guard bottleLeases.acquireShared(bottle.id) else {
            lastErrorMessage = String(
                localized: "This bottle is busy with another operation. Wait for it to finish, then try again."
            )
            return
        }
        defer { bottleLeases.releaseShared(bottle.id) }
        // Mark a launch in flight (synchronously, before the await) so a GPTK
        // import — which refuses while launchingIDs is non-empty — can't swap
        // the shared runtime while wine loads this program. A synthetic id (not
        // a program's) so it never lights up a program card's "Starting…".
        let launchMarker = UUID()
        launchingIDs.insert(launchMarker)
        defer { launchingIDs.remove(launchMarker) }
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
            // The bottle's wineserver is still alive after the wait. Clear the
            // transient "Closing…" flag so the cards revert to Running + Stop
            // (the user can retry or Force Stop All) instead of a spinner with
            // no button. No error is surfaced here on purpose: this probe is
            // whole-bottle, not per-program, so it also stays active during a
            // slow-but-normal shutdown or while a sibling program keeps
            // running — treating that as "failed to stop" would be a false
            // alarm. A reliable per-program signal is future work.
            for program in bottle.programs {
                closingIDs.remove(program.id)
            }
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

    /// Graphics settings tuned to this Mac's display for `bottle`'s runtime, or
    /// nil when no display is detectable. Built on top of the bottle's current
    /// settings so unrelated fields survive. The settings sheet's "Recommend"
    /// button applies the result to its draft — existing bottles change only if
    /// the user then saves.
    func recommendedSettings(for bottle: Bottle) async -> BottleSettings? {
        guard let hardware = hardwareProfileProvider() else { return nil }
        let id = bottle.runtimeID ?? manifest.defaultRuntimeID
        guard let descriptor = try? await runtimeStore.descriptor(id: id) else { return nil }
        return PerformanceAdvisor.recommend(for: hardware, runtime: descriptor, base: bottle.settings)
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

    func report(_ error: any Error) {
        lastErrorMessage = error.localizedDescription
    }

    /// Refuses (with a message) when a shared-runtime maintenance op holds the
    /// lease: launches, bottle creation, and installs must not start while the
    /// runtime is being replaced. Returns true when blocked. Synchronous, so
    /// callers check it before their first await/state change.
    func blockedByRuntimeMaintenance() -> Bool {
        guard runtimeMaintenanceInProgress else { return false }
        lastErrorMessage = String(
            localized: "The graphics runtime is being updated. Wait for it to finish, then try again."
        )
        return true
    }

    /// Icon for a program card. Extracts lazily for programs registered
    /// before icon support (or after Steam's bootstrap replaced the exe).
    func iconURL(for program: Program, in bottle: Bottle) async -> URL? {
        let bottleDirectory = await bottleStore.directory(of: bottle)
        let url = ProgramIconStore.iconURL(programID: program.id, bottleDirectory: bottleDirectory)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        let exe = WindowsPath.toUnix(program.windowsPath, prefix: prefix)
        // Extracting an icon memory-maps and parses the .exe (up to hundreds of
        // MB) — do it off the main actor so a program card can't stutter the UI.
        let programID = program.id
        return await Task.detached(priority: .utility) {
            ProgramIconStore.extractAndStore(
                exe: exe,
                programID: programID,
                bottleDirectory: bottleDirectory
            )
        }.value
    }

    /// Probes live whether any bottle currently has a running wineserver — used
    /// to refuse shared-runtime maintenance while a program is running, without
    /// relying on the possibly-stale `activeBottleIDs` snapshot.
    func anyBottleActive() async -> Bool {
        for bottle in bottles {
            let prefix = await bottleStore.prefixDirectory(of: bottle)
            if activityProbe.isActive(prefix: prefix) {
                return true
            }
        }
        return false
    }
}

public extension AppState {
    var needsOnboarding: Bool {
        if case .ready = runtimeStatus {
            return false
        }
        return true
    }

    var defaultRuntimeID: String {
        manifest.defaultRuntimeID
    }

    /// Install/migration progress for `bottle`, or nil when a *different*
    /// bottle (or none) is installing — so switching to another bottle's view
    /// no longer shows a sibling's progress bar.
    func installProgress(for bottle: Bottle) -> (phase: InstallPhase, fraction: Double)? {
        guard let activeInstall, activeInstall.bottleID == bottle.id else { return nil }
        return (activeInstall.phase, activeInstall.fraction)
    }

    /// True while any bottle has an install/migration in flight. Installs mutate
    /// a Wine prefix and share one progress/token slot, so only one runs at a
    /// time — the UI disables starting a second from another bottle's view.
    var isInstalling: Bool {
        activeInstall != nil
    }
}
