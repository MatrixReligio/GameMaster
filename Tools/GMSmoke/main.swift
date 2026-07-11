import Foundation
import GMBottles
import GMLaunch
import GMModel
import GMRuntime
import GMSystem

// A command-line end-to-end smoke test of the GameMaster engine against a REAL
// wine runtime. It exercises the exact pipeline the app uses: install runtime →
// create bottle → wineboot → run a Windows program. Intended for local
// verification and CI smoke runs, not shipped in the app.
//
// Env:
//   GM_RUNTIME_TARBALL  local .tar.xz to install instead of downloading (optional)
//   GM_STEAM_EXE        local SteamSetup.exe to install (optional)
//   GM_ROOT             app-support root (default: a temp dir)
//   GM_LAUNCH_STEAM     if "1", launch steam.exe after install (needs a display)

@main
struct GMSmoke {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("SMOKE FAILED: \(error)\n".utf8))
            exit(1)
        }
    }

    static func log(_ message: String) {
        print("[smoke] \(message)")
        fflush(stdout)
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["GM_ROOT"]
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-smoke-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        log("root: \(root.path)")

        let runner = SubprocessRunner()
        let runtimeStore = RuntimeStore(root: root)
        let bottleStore = BottleStore(root: root)
        let manifest = try RuntimeManifest.bundled()
        let entry = try requireEntry(manifest)

        // 1. Install runtime — from a local tarball if provided (fast), else download.
        let descriptor: RuntimeDescriptor
        if let existing = try await runtimeStore.descriptor(id: entry.id) {
            log("runtime already installed: \(existing.id)")
            descriptor = existing
        } else if let tarball = env["GM_RUNTIME_TARBALL"] {
            descriptor = try await installFromTarball(
                tarball: URL(fileURLWithPath: tarball),
                entry: entry,
                store: runtimeStore,
                runner: runner
            )
        } else {
            log("downloading runtime \(entry.url.absoluteString) …")
            let installer = RuntimeInstaller(store: runtimeStore, downloader: URLSessionDownloader(), runner: runner)
            descriptor = try await installer.install(entry: entry) { phase, fraction in
                log("  \(phase) \(Int(fraction * 100))%")
            }
        }
        log("runtime ready: \(descriptor.id) gptk=\(descriptor.gptk)")

        let wine = await runtimeStore.wineBinary(for: descriptor)
        guard FileManager.default.fileExists(atPath: wine.path) else {
            throw SmokeError.missing("wine binary at \(wine.path)")
        }
        log("wine binary: \(wine.path)")

        // Optional: import Apple's D3DMetal from a mounted evaluation volume,
        // exercising the exact GPTKImporter path the app's UI uses.
        if let volumePath = env["GM_IMPORT_VOLUME"] {
            log("importing D3DMetal from mounted volume: \(volumePath)")
            let importer = GPTKImporter(
                store: runtimeStore,
                mounter: NoopMounter(),
                runner: runner
            )
            let updated = try await importer.importGPTK(
                mountedVolume: URL(fileURLWithPath: volumePath),
                into: descriptor.id
            )
            let framework = await runtimeStore.wineBinary(for: updated)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/external/D3DMetal.framework/Versions/A/D3DMetal")
            guard FileManager.default.fileExists(atPath: framework.path) else {
                throw SmokeError.missing("D3DMetal.framework after import")
            }
            // A core builtin must survive the merge (not bricked).
            let ntdll = await runtimeStore.wineBinary(for: updated)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
            let ntdllOK = FileManager.default.fileExists(atPath: ntdll.path)
            log("✅ D3DMetal imported: \(updated.gptk); core builtin ntdll.so present=\(ntdllOK)")
        }

        // 2. Create + initialize a bottle with real wineboot.
        let bottle = try await bottleStore.create(name: "Smoke Bottle", runtimeID: descriptor.id)
        let launcher = WineLauncher(
            runtimeStore: runtimeStore,
            bottleStore: bottleStore,
            runner: runner,
            logsRoot: root.appendingPathComponent("logs"),
            defaultRuntimeID: descriptor.id
        )
        log("wineboot --init (this takes a while on first run) …")
        try await launcher.initializeBottle(bottle)
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c").path) else {
            throw SmokeError.missing("drive_c after wineboot")
        }
        log("prefix initialized: \(prefix.path)")

        // 3. Install Steam if an installer is available.
        if let steamExe = env["GM_STEAM_EXE"] {
            log("installing Steam (silent) …")
            let result = try await launcher.run(
                exe: URL(fileURLWithPath: steamExe),
                arguments: ["/S"],
                in: bottle,
                wait: true
            )
            log("Steam installer exit: \(result.exitCode)")
            let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
            if FileManager.default.fileExists(atPath: steam.path) {
                log("✅ steam.exe present at \(steam.path)")
            } else {
                log("⚠️ steam.exe not found after install (see logs)")
            }

            if env["GM_LAUNCH_STEAM"] == "1" {
                log("launching Steam (needs a display) …")
                let program = Program(
                    name: "Steam",
                    windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
                    arguments: ["-allosarches", "-cef-force-32bit", "-noverifyfiles"]
                )
                _ = try await launcher.launch(program, in: bottle)
            }
        }

        log("✅ SMOKE PASSED")
    }

    static func installFromTarball(
        tarball: URL,
        entry: RuntimeManifest.Entry,
        store: RuntimeStore,
        runner: SubprocessRunner
    ) async throws -> RuntimeDescriptor {
        log("installing runtime from local tarball \(tarball.lastPathComponent) …")
        let digest = try SHA256.hexDigest(of: tarball)
        guard digest == entry.sha256.lowercased() else {
            throw SmokeError.checksum(expected: entry.sha256, actual: digest)
        }
        let installer = RuntimeInstaller(
            store: store,
            downloader: LocalFileDownloader(source: tarball),
            runner: runner
        )
        return try await installer.install(entry: entry) { phase, _ in log("  \(phase)") }
    }

    static func requireEntry(_ manifest: RuntimeManifest) throws -> RuntimeManifest.Entry {
        guard let entry = manifest.defaultEntry else { throw SmokeError.missing("default manifest entry") }
        return entry
    }
}

/// Copies a local file in place of a network download (for the smoke harness).
struct LocalFileDownloader: Downloading {
    let source: URL
    func download(from _: URL, to destination: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        progress?(1.0)
    }
}

/// Passes a pre-mounted volume straight through (the smoke harness mounts the
/// DMG via Finder / hdiutil out of band).
struct NoopMounter: DiskImageMounting {
    func mount(dmg: URL) async throws -> URL {
        dmg
    }

    func unmount(_: URL) async {}
}

enum SmokeError: Error, CustomStringConvertible {
    case missing(String)
    case checksum(expected: String, actual: String)

    var description: String {
        switch self {
        case let .missing(what): "missing \(what)"
        case let .checksum(expected, actual): "checksum mismatch expected=\(expected) actual=\(actual)"
        }
    }
}
