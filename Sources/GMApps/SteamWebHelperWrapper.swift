import Foundation
import GMLaunch

/// Installs (and repairs) Steam's CEF web-helper wrapper inside a prefix.
///
/// Steam's `steamwebhelper.exe` is a Chromium (CEF) process whose GPU compositor
/// never completes under Wine, so its UI renders black. The fix is to relaunch
/// it with software-rendering flags, but Steam controls how it spawns the helper
/// and won't pass them. So we rename the real helper to `steamwebhelper_real.exe`
/// and drop a tiny wrapper in its place that forwards every argument plus the
/// compatibility flags. See `Tools/SteamWebHelperWrapper/`.
public enum SteamWebHelperWrapper {
    /// The wrapper is ~150 KB; the genuine helper is several MB. Anything larger
    /// than this in the helper slot is the real binary (fresh install or a Steam
    /// self-update that overwrote our wrapper), so we must re-back-it-up.
    static let realHelperMinBytes = 1_048_576

    public enum WrapperError: Error, Equatable {
        case wrapperResourceMissing(name: String)
    }

    /// Idempotent: safe to call on every launch. Does nothing if Steam hasn't
    /// been bootstrapped yet (the helper doesn't exist). If Steam updated over
    /// our wrapper, re-captures the genuine helper and reinstalls the wrapper.
    public static func install(
        spec: InstallerCatalog.WebHelperWrapper,
        prefix: URL,
        wrapperResource: URL
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: wrapperResource.path) else {
            throw WrapperError.wrapperResourceMissing(name: spec.wrapperResourceName)
        }

        let cefDir = WindowsPath.toUnix(spec.cefWindowsDirectory, prefix: prefix)
        let helper = cefDir.appendingPathComponent(spec.helperFileName)
        let realHelper = cefDir.appendingPathComponent(spec.realHelperFileName)

        // Steam not bootstrapped yet — nothing to wrap. First real launch (under
        // the run runtime) will have this called again by the launch path.
        guard fm.fileExists(atPath: helper.path) else { return }

        // If the genuine binary is sitting in the helper slot (first install, or
        // a Steam update replaced our wrapper), capture it as the real helper.
        if fileSize(of: helper) > realHelperMinBytes {
            if fm.fileExists(atPath: realHelper.path) {
                try fm.removeItem(at: realHelper)
            }
            try fm.copyItem(at: helper, to: realHelper)
        }

        // Only overwrite the helper slot once we have a real backup to forward to.
        guard fm.fileExists(atPath: realHelper.path) else { return }
        if fm.fileExists(atPath: helper.path) {
            try fm.removeItem(at: helper)
        }
        try fm.copyItem(at: wrapperResource, to: helper)
    }

    /// Bundled wrapper resource URL, if present.
    public static func bundledResource(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "exe")
    }

    private static func fileSize(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
