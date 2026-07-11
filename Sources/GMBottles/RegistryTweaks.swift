import Foundation

/// Generates .reg payloads applied with `wine regedit` at bottle setup.
public enum RegistryTweaks {
    /// Retina mode makes wine render at native pixel density instead of
    /// scaled-up blurriness on HiDPI displays.
    public static func retinaRegContent(enabled: Bool) -> String {
        """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="\(enabled ? "y" : "n")"

        """
    }
}
