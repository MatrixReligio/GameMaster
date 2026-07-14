import Foundation
import GMBottles
import GMLaunch
import GMModel
import GMRuntime
import GMSystem

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
        guard !blockedByRuntimeMaintenance() else { return }
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
        // One install/migration at a time (see installCatalogApp): don't race a
        // concurrent install's prefix writes and shared progress slot.
        guard activeInstall == nil else { throw AppInstallError.anotherInstallInProgress }
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
        let program: Program
        do {
            program = try await programLibrary.addProgram(exe: exe, name: nil, in: bottle)
        } catch {
            report(error)
            return
        }
        await refresh()
        await launch(program: program, in: bottle)
    }

    func runExe(_ exe: URL, in bottle: Bottle) async {
        guard !blockedByRuntimeMaintenance() else { return }
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
}
