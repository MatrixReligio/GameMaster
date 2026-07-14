import Foundation
import GMLaunch
import GMRuntime

/// Replaces Steam's crashing 32-bit `steamservice.exe` with a no-op stub.
///
/// The real Steam Client Service null-derefs under modern Wine's new WoW64,
/// popping a "Steam Service Error" dialog on every launch. The service is only
/// needed for elevated installs (bundled runtimes, some anti-cheat), not for
/// login or downloads, so a do-nothing stub that registers a dummy service and
/// exits cleanly silences the dialog with no functional loss for the client UI.
/// See `Tools/SteamServiceStub/`.
public enum SteamServiceStub {
    public enum StubError: Error, Equatable {
        case stubResourceMissing(name: String)
    }

    /// Idempotent: replaces each target that isn't already the stub, keeping a
    /// `.real` backup. Missing targets are skipped (Steam recreates the service
    /// exe from `bin/` on first run, and that copy is stubbed too).
    public static func install(
        spec: InstallerCatalog.ServiceStub,
        prefix: URL,
        stubResource: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stubResource.path) else {
            throw StubError.stubResourceMissing(name: spec.stubResourceName)
        }
        let stubSize = fileSize(of: stubResource)

        for windowsPath in spec.windowsPaths {
            let target = WindowsPath.toUnix(windowsPath, prefix: prefix)
            guard fm.fileExists(atPath: target.path) else { continue }
            // Already the stub (identical size) — leave it.
            if fileSize(of: target) == stubSize {
                continue
            }

            // Back up the genuine service, then drop the stub in its place —
            // both atomically: wine loads this executable, and two launches can
            // touch one prefix, so no removeItem→copyItem gap must be visible.
            let backup = target.appendingPathExtension("real")
            try AtomicFile.replace(at: backup, withCopyOf: target)
            try AtomicFile.replace(at: target, withCopyOf: stubResource)
        }
    }

    public static func bundledResource(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "exe")
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
    }
}
