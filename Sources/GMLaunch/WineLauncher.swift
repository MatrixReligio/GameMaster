import Foundation
import GMBottles
import GMModel
import GMRuntime
import GMSystem

public enum LaunchError: Error, LocalizedError, Equatable {
    case runtimeMissing(id: String)

    public var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            String(localized: "The Windows runtime is not installed yet. Open Settings → Runtime to install it.")
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

    public init(
        runtimeStore: RuntimeStore,
        bottleStore: BottleStore,
        runner: any ProcessRunning,
        logsRoot: URL,
        defaultRuntimeID: String
    ) {
        self.runtimeStore = runtimeStore
        self.bottleStore = bottleStore
        self.runner = runner
        self.logsRoot = logsRoot
        self.defaultRuntimeID = defaultRuntimeID
    }

    /// Boots a fresh prefix (`wineboot --init`) and applies registry tweaks.
    public func initializeBottle(_ bottle: Bottle) async throws {
        let context = try await context(for: bottle)
        _ = try await runner.run(
            executable: context.wineBinary,
            arguments: ["wineboot", "--init"],
            environment: context.environment,
            currentDirectory: nil,
            outputLine: nil
        )
        let regFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamemaster-retina-\(UUID().uuidString).reg")
        try RegistryTweaks.retinaRegContent(enabled: bottle.settings.retinaMode)
            .write(to: regFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: regFile) }
        _ = try await runner.run(
            executable: context.wineBinary,
            arguments: ["regedit", "/S", regFile.path],
            environment: context.environment,
            currentDirectory: nil,
            outputLine: nil
        )
    }

    /// Runs a registered program (windows path resolved inside the prefix).
    @discardableResult
    public func launch(_ program: Program, in bottle: Bottle) async throws -> ProcessResult {
        let context = try await context(for: bottle)
        let exe = WindowsPath.toUnix(program.windowsPath, prefix: context.prefix)
        return try await start(
            exe: exe,
            arguments: program.arguments,
            extraEnvironment: program.environment,
            logName: program.name,
            context: context
        )
    }

    /// Runs an arbitrary executable (e.g. a dropped installer) in the bottle.
    @discardableResult
    public func run(exe: URL, arguments: [String], in bottle: Bottle) async throws -> ProcessResult {
        let context = try await context(for: bottle)
        return try await start(
            exe: exe,
            arguments: arguments,
            extraEnvironment: [:],
            logName: exe.deletingPathExtension().lastPathComponent,
            context: context
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

    // MARK: - Internals

    private struct Context {
        var wineBinary: URL
        var prefix: URL
        var environment: [String: String]
    }

    private func context(for bottle: Bottle) async throws -> Context {
        let runtimeID = bottle.runtimeID ?? defaultRuntimeID
        guard let descriptor = try await runtimeStore.descriptor(id: runtimeID) else {
            throw LaunchError.runtimeMissing(id: runtimeID)
        }
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        let environment = EnvironmentComposer.environment(for: bottle, prefix: prefix, runtime: descriptor)
        return await Context(
            wineBinary: runtimeStore.wineBinary(for: descriptor),
            prefix: prefix,
            environment: environment
        )
    }

    private func start(
        exe: URL,
        arguments: [String],
        extraEnvironment: [String: String],
        logName: String,
        context: Context
    ) async throws -> ProcessResult {
        var environment = context.environment
        environment.merge(extraEnvironment) { _, program in program }

        let log = try makeLogFile(
            bottleDirectoryName: context.prefix
                .deletingLastPathComponent().lastPathComponent,
            logName: logName
        )
        // `start /unix` lets wine handle .exe, .msi, and .lnk uniformly.
        return try await runner.run(
            executable: context.wineBinary,
            arguments: ["start", "/unix", exe.path] + arguments,
            environment: environment,
            currentDirectory: nil
        ) { line in
            log.append(line)
        }
    }

    private func makeLogFile(bottleDirectoryName: String, logName: String) throws -> LogWriter {
        let dir = logsRoot.appendingPathComponent(bottleDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let safeName = logName.replacingOccurrences(of: "/", with: "-")
        return LogWriter(file: dir.appendingPathComponent("\(stamp)-\(safeName).log"))
    }
}
