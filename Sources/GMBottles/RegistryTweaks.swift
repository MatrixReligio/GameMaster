import Foundation

/// Generates .reg payloads applied with `wine regedit` at bottle setup.
public enum RegistryTweaks {
    /// Retina mode makes wine render at native pixel density instead of
    /// scaled-up blurriness on HiDPI displays. It MUST be paired with 2x
    /// Windows DPI (LogPixels 192, 0xc0) or all UI draws at half size;
    /// disabling restores the standard 96 DPI (0x60).
    public static func retinaRegContent(enabled: Bool) -> String {
        """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="\(enabled ? "y" : "n")"

        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "LogPixels"=dword:\(enabled ? "000000c0" : "00000060")

        """
    }
}
