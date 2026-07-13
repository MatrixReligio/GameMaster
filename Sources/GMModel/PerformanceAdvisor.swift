import Foundation

/// What the running Mac's display looks like to the advisor. `logicalWidth` is
/// the point width macOS reports — the resolution Wine renders at when Retina is
/// off; `physicalWidth` is the backing width the display composites at
/// (logical × backing scale). Their ratio is the display scale — the factor
/// MetalFX must upscale by so its output fills the backing exactly. (On a scaled
/// mode the backing can exceed the panel's native pixels; the scale is still the
/// right upscale target.)
public struct HardwareProfile: Equatable, Sendable {
    public var physicalWidth: Int
    public var logicalWidth: Int
    public var refreshHz: Int

    public init(physicalWidth: Int, logicalWidth: Int, refreshHz: Int) {
        self.physicalWidth = physicalWidth
        self.logicalWidth = logicalWidth
        self.refreshHz = refreshHz
    }

    /// Display backing scale (physical ÷ logical). 1.0 for a non-HiDPI panel,
    /// 2.0 for a 4K screen shown at "looks like 1080p". Guards against a bogus
    /// zero logical width.
    public var displayScale: Double {
        logicalWidth > 0 ? Double(physicalWidth) / Double(logicalWidth) : 1
    }
}

/// Turns the detected display + chosen runtime into good graphics defaults.
///
/// Grounded in on-device CS2 measurement (M4 Max, 4K@60): the GPU sat ~30 %
/// utilised behind a CPU/translation bottleneck, so rendering at the Retina-off
/// logical resolution and letting MetalFX upscale to native is sharp *and*
/// nearly free. The advisor only sets the display-driven graphics fields and
/// leaves everything else on the caller's `base` untouched — and it is only ever
/// applied to new bottles or on explicit request, never silently to existing ones.
public enum PerformanceAdvisor {
    /// Scale at or above which MetalFX should upscale ×2 rather than ×1.5.
    private static let doubleScaleThreshold = 1.75
    /// Below this scale the display is effectively non-HiDPI: nothing to upscale.
    private static let hiDPIThreshold = 1.05

    public static func recommend(
        for hardware: HardwareProfile,
        runtime: RuntimeDescriptor,
        base: BottleSettings = BottleSettings()
    ) -> BottleSettings {
        var settings = base
        let scale = hardware.displayScale
        let isDXMT = if case .installed = runtime.dxmt {
            true
        } else {
            false
        }

        // MetalFX only helps when there is a real gap to upscale across (a
        // HiDPI-scaled panel) and the runtime is DXMT — on GPTK the switch means
        // DLSS conversion, which is game-specific and mutates the shared runtime.
        if isDXMT, scale >= hiDPIThreshold {
            // Render at the logical resolution, not the doubled Retina backing:
            // far fewer pixels, and MetalFX restores the sharpness.
            settings.retinaMode = false
            settings.metalFX = true
            settings.metalFXUpscaleFactor = scale >= doubleScaleThreshold ? 2.0 : 1.5
        } else {
            // No MetalFX to recover sharpness (GPTK, or a non-HiDPI panel): keep
            // the caller's Retina setting rather than rendering at low resolution
            // with nothing to upscale it back — that would just degrade quality.
            settings.metalFX = false
            settings.metalFXUpscaleFactor = nil
        }

        // The frame-rate cap is not a display-driven field, so leave whatever
        // the caller had: a new bottle's base is uncapped (best for a
        // competitive game — extra frames cut input latency even above the
        // refresh rate), and a cap the user set by hand is preserved rather
        // than silently reset when they press "Recommend".
        return settings
    }
}
