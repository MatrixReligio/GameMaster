import Foundation
import GMBottles
import GMModel
import GMRuntime
import GMSystem

public enum LaunchError: Error, LocalizedError, Equatable {
    case runtimeMissing(id: String)
    case commandFailed(command: String, exitCode: Int32)
    case runtimeUnderMaintenance

    public var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            String(localized: "The Windows runtime is not installed yet. Open Settings → Runtime to install it.")
        case let .commandFailed(command, exitCode):
            String(localized: "“\(command)” failed (exit code \(exitCode)). Check the bottle's logs for details.")
        case .runtimeUnderMaintenance:
            String(localized: "The graphics runtime is being updated. Wait for it to finish, then try again.")
        }
    }
}

/// Launches Windows programs in a bottle via the bottle's wine runtime,
/// captures output to per-launch log files, and can stop everything.
public struct WineLauncher: Sendable {
    private let runtimeStore: RuntimeStore
    private let bottleStore: BottleStore
    private let runner: any ProcessRunning
    private let logsRoot: URL
    private let defaultRuntimeID: String
    /// Read at the single `context(for:)` choke point (and before MetalFX
    /// prep): while it returns true a GPTK import is replacing the shared
    /// runtime, so every wine process is refused. Defaults to always-false so
    /// callers that never import (and tests) need not supply it.
    private let isUnderMaintenance: @Sendable () -> Bool

    public init(
        runtimeStore: RuntimeStore,
        bottleStore: BottleStore,
        runner: any ProcessRunning,
        logsRoot: URL,
        defaultRuntimeID: String,
        isUnderMaintenance: @escaping @Sendable () -> Bool = { false }
    ) {
        self.runtimeStore = runtimeStore
        self.bottleStore = bottleStore
        self.runner = runner
        self.logsRoot = logsRoot
        self.defaultRuntimeID = defaultRuntimeID
        self.isUnderMaintenance = isUnderMaintenance
    }

    /// Boots a fresh prefix (`wineboot --init`) and applies registry tweaks.
    public func initializeBottle(_ bottle: Bottle) async throws {
        let context = try await context(for: bottle)

        // Disable wine's automatic mono/.NET and gecko/HTML installers for the
        // first boot. The bundled versions in the runtime can mismatch the wine
        // build, which makes wine DOWNLOAD them and abort with a checksum error
        // dialog ("Wine Mono Installer: Unexpected checksum…"). Steam and games
        // don't need them; a specific game can install .NET later via winetricks.
        var initEnvironment = context.environment
        initEnvironment["WINEDLLOVERRIDES"] = Self.mergeOverrides(
            initEnvironment["WINEDLLOVERRIDES"],
            adding: ["mscoree=", "mshtml="]
        )

        let boot = try await runner.run(
            executable: context.wineBinary,
            arguments: ["wineboot", "--init"],
            environment: initEnvironment,
            currentDirectory: nil,
            outputLine: nil
        )
        guard boot.exitCode == 0 else {
            throw LaunchError.commandFailed(command: "wineboot", exitCode: boot.exitCode)
        }
        try await applyRetinaRegistry(in: bottle, context: context)
    }

    /// Writes the Retina/DPI registry tweak for the bottle's CURRENT setting.
    /// Retina lives in the Wine registry, so toggling it in Bottle Settings
    /// must call this — saving the JSON alone changes nothing at runtime.
    public func applyRetinaRegistry(in bottle: Bottle) async throws {
        try await applyRetinaRegistry(in: bottle, context: context(for: bottle))
    }

    private func applyRetinaRegistry(in bottle: Bottle, context: Context) async throws {
        let regFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamemaster-retina-\(UUID().uuidString).reg")
        try RegistryTweaks.retinaRegContent(enabled: bottle.settings.retinaMode)
            .write(to: regFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: regFile) }
        let result = try await runner.run(
            executable: context.wineBinary,
            arguments: ["regedit", "/S", regFile.path],
            environment: context.environment,
            currentDirectory: nil,
            outputLine: nil
        )
        guard result.exitCode == 0 else {
            throw LaunchError.commandFailed(command: "regedit", exitCode: result.exitCode)
        }
    }

    /// Runs a registered program (windows path resolved inside the prefix).
    /// Uses `/wait` so the call stays suspended for the program's lifetime —
    /// the caller's running-state tracking then reflects reality.
    @discardableResult
    public func launch(_ program: Program, in bottle: Bottle) async throws -> ProcessResult {
        try await prepareMetalFXIfNeeded(for: bottle)
        let context = try await context(for: bottle)
        let exe = WindowsPath.toUnix(program.windowsPath, prefix: context.prefix)
        return try await start(
            exe: exe,
            arguments: Self.sanitizedArguments(program.arguments),
            extraEnvironment: program.environment,
            logName: program.name,
            context: context,
            wait: true
        )
    }

    /// Launch arguments that break current software and must be dropped even
    /// from bottles saved by older app versions. `-cef-force-32bit` is a dead
    /// 2023 Steam workaround: Steam removed 32-bit CEF in 2024, and passing it
    /// now throws steamwebhelper into an infinite "not responding" restart loop.
    static let deadArguments: Set<String> = ["-cef-force-32bit"]

    static func sanitizedArguments(_ arguments: [String]) -> [String] {
        arguments.filter { !deadArguments.contains($0) }
    }

    /// Runs an arbitrary executable (e.g. a dropped installer) in the bottle.
    /// `wait: true` blocks until the Windows process exits (installers).
    @discardableResult
    public func run(
        exe: URL,
        arguments: [String],
        in bottle: Bottle,
        wait: Bool = false
    ) async throws -> ProcessResult {
        try await prepareMetalFXIfNeeded(for: bottle)
        let context = try await context(for: bottle)
        return try await start(
            exe: exe,
            arguments: arguments,
            extraEnvironment: [:],
            logName: exe.deletingPathExtension().lastPathComponent,
            context: context,
            wait: wait
        )
    }

    /// Sends a control command to a running program (e.g. Steam's `-shutdown`,
    /// routed through the running instance to save state). Unlike `run`, this
    /// NEVER performs MetalFX file prep: stopping a program must not depend on —
    /// and fail because of — launch-time graphics preparation. Always
    /// fire-and-forget (`wait: false`); the program exits on its own.
    @discardableResult
    public func runControlCommand(
        exe: URL,
        arguments: [String],
        in bottle: Bottle
    ) async throws -> ProcessResult {
        let context = try await context(for: bottle)
        return try await start(
            exe: exe,
            arguments: arguments,
            extraEnvironment: [:],
            logName: exe.deletingPathExtension().lastPathComponent,
            context: context,
            wait: false
        )
    }

    /// Asks a running Windows program to close gracefully: `taskkill` without
    /// `/F` sends WM_CLOSE — the same as clicking the window's close button —
    /// so the program can save state or show its own confirmation dialog.
    /// `stopAll` remains the hard kill for stuck processes.
    ///
    /// A nonzero taskkill exit is deliberately not surfaced: it means the
    /// process was already gone (the common case) and the card resolves via
    /// the launch call returning; a stuck program still has Force Stop All.
    public func taskkill(imageName: String, in bottle: Bottle) async throws {
        let context = try await context(for: bottle)
        _ = try await runner.run(
            executable: context.wineBinary,
            arguments: ["taskkill", "/IM", imageName],
            environment: context.environment,
            currentDirectory: nil,
            outputLine: nil
        )
    }

    /// Kills every wine process of the bottle (`wineserver -k`).
    public func stopAll(in bottle: Bottle) async throws {
        let context = try await context(for: bottle)
        let wineserver = context.wineBinary.deletingLastPathComponent()
            .appendingPathComponent("wineserver")
        _ = try await runner.run(
            executable: wineserver,
            arguments: ["-k"],
            environment: context.environment,
            currentDirectory: nil,
            outputLine: nil
        )
    }

    /// Merges additional `module=` directives into a WINEDLLOVERRIDES string
    /// (semicolon-separated), preserving any existing entries (e.g. D3DMetal).
    static func mergeOverrides(_ existing: String?, adding: [String]) -> String {
        var parts: [String] = []
        if let existing, !existing.isEmpty {
            parts.append(existing)
        }
        parts.append(contentsOf: adding)
        return parts.joined(separator: ";")
    }

    /// Mirrors DXMT's winemetal.dll from the runtime into the prefix's
    /// system32. The d3d11/dxgi builtins load it by name, and wine resolves
    /// that reliably only when the DLL is also visible inside the prefix.
    /// Idempotent (size compare) and reapplied on every launch, because a
    /// prefix reset or client self-update can drop the copy.
    static func ensureDXMTPrefixSupport(runtime: RuntimeDescriptor, wineBinary: URL, prefix: URL) {
        guard case .installed = runtime.dxmt else { return }
        let source = wineBinary
            .deletingLastPathComponent() // bin/
            .deletingLastPathComponent() // wine root
            .appendingPathComponent("lib/wine/x86_64-windows/winemetal.dll")
        let fm = FileManager.default
        guard let sourceSize = fileSize(of: source) else { return }
        let target = prefix.appendingPathComponent("drive_c/windows/system32/winemetal.dll")
        if fileSize(of: target) == sourceSize {
            return
        }
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: source, to: target)
    }

    private static func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    // MARK: - Internals

    private struct Context {
        var wineBinary: URL
        var prefix: URL
        var environment: [String: String]
    }

    private func context(for bottle: Bottle) async throws -> Context {
        // The single arbiter. EVERY method that starts a wine process resolves
        // its context here first, so refusing when the shared runtime is under
        // maintenance (a GPTK import) closes off all of them at once — launch,
        // run, stop, control commands, taskkill, retina registry, boot — and
        // any entry point added later, with no new scattered guard to forget.
        if isUnderMaintenance() {
            throw LaunchError.runtimeUnderMaintenance
        }
        let runtimeID = bottle.runtimeID ?? defaultRuntimeID
        guard let descriptor = try await runtimeStore.descriptor(id: runtimeID) else {
            throw LaunchError.runtimeMissing(id: runtimeID)
        }
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        let environment = EnvironmentComposer.environment(for: bottle, prefix: prefix, runtime: descriptor)
        let wineBinary = await runtimeStore.wineBinary(for: descriptor)
        Self.ensureDXMTPrefixSupport(runtime: descriptor, wineBinary: wineBinary, prefix: prefix)
        return Context(
            wineBinary: wineBinary,
            prefix: prefix,
            environment: environment
        )
    }

    /// Activates GPTK's DLSS-to-MetalFX shims (nvngx-on-metalfx.*) for this
    /// bottle before a program launch. Deliberately NOT part of `context()`:
    /// stop commands (taskkill, wineserver -k) and wineboot also use `context`,
    /// and must work even when the MetalFX files are broken — so this throwing
    /// file prep runs only on the launch/run paths. DXMT handles MetalFX purely
    /// via environment, so there is nothing to prepare there. Prep is
    /// non-destructive and idempotent, so a failure surfaces at launch instead
    /// of running with the env claiming MetalFX while the shim never landed.
    private func prepareMetalFXIfNeeded(for bottle: Bottle) async throws {
        // launch/run prep the runtime BEFORE resolving context(), so this file
        // write into the shared runtime must also stand down during a GPTK
        // import — otherwise the backstop would miss the one path that touches
        // the runtime ahead of the context() choke point.
        if isUnderMaintenance() {
            throw LaunchError.runtimeUnderMaintenance
        }
        guard bottle.settings.metalFX else { return }
        let runtimeID = bottle.runtimeID ?? defaultRuntimeID
        guard let descriptor = try await runtimeStore.descriptor(id: runtimeID),
              case .installed = descriptor.gptk else { return }
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        try await MetalFXEnabler(store: runtimeStore).prepare(runtimeID: runtimeID, prefix: prefix)
    }

    private func start(
        exe: URL,
        arguments: [String],
        extraEnvironment: [String: String],
        logName: String,
        context: Context,
        wait: Bool = false
    ) async throws -> ProcessResult {
        var environment = context.environment
        environment.merge(extraEnvironment) { _, program in program }

        // `start /unix` lets wine handle .exe, .msi, and .lnk uniformly.
        let startArguments = wait ? ["start", "/wait", "/unix"] : ["start", "/unix"]

        // Fire-and-forget launches must NOT capture output: the wine `start`
        // helper exits immediately but the launched program inherits the
        // output pipe, so waiting for its EOF would block until the whole
        // program tree exits — exactly what wait:false is meant to avoid.
        guard wait else {
            return try await runner.run(
                executable: context.wineBinary,
                arguments: startArguments + [exe.path] + arguments,
                environment: environment,
                currentDirectory: nil,
                outputLine: nil
            )
        }

        let log = try makeLogFile(
            bottleDirectoryName: context.prefix
                .deletingLastPathComponent().lastPathComponent,
            logName: logName
        )
        return try await runner.run(
            executable: context.wineBinary,
            arguments: startArguments + [exe.path] + arguments,
            environment: environment,
            currentDirectory: nil
        ) { line in
            log.append(line)
        }
    }

    /// How many launch logs to keep per bottle. Wine sessions are chatty
    /// (MoltenVK banners, CEF noise), so unbounded logs quietly eat disk.
    static let logRetentionCount = 10

    private func makeLogFile(bottleDirectoryName: String, logName: String) throws -> LogWriter {
        let dir = logsRoot.appendingPathComponent(bottleDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.pruneOldLogs(in: dir, keeping: Self.logRetentionCount - 1)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let safeName = logName.replacingOccurrences(of: "/", with: "-")
        return LogWriter(file: dir.appendingPathComponent("\(stamp)-\(safeName).log"))
    }

    /// Deletes all but the newest `keeping` logs in a bottle's log directory.
    /// The timestamped file names sort chronologically.
    static func pruneOldLogs(in directory: URL, keeping: Int) {
        let fm = FileManager.default
        guard let logs = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "log" })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        else { return }
        for stale in logs.dropFirst(max(0, keeping)) {
            try? fm.removeItem(at: stale)
        }
    }
}
