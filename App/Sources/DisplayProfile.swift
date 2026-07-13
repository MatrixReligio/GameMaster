import AppKit
import GMModel

/// Reads the running Mac's main display into a `HardwareProfile` for the
/// performance advisor. Lives in the app layer so GMApps stays free of AppKit.
enum DisplayProfile {
    /// The main display's profile, or nil if none is attached (headless).
    /// `physicalWidth` is the backing width the display composites at
    /// (points × backing scale) — the resolution MetalFX should target — which
    /// on a 2× Retina panel equals the native pixel width.
    @MainActor
    static func detect() -> HardwareProfile? {
        guard let screen = NSScreen.main else { return nil }
        let logical = Int(screen.frame.width.rounded())
        guard logical > 0 else { return nil }
        let backing = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        let refresh = screen.maximumFramesPerSecond
        return HardwareProfile(
            physicalWidth: backing,
            logicalWidth: logical,
            refreshHz: refresh > 0 ? refresh : 60
        )
    }
}
