import Testing
@testable import GMModel

/// The advisor turns what we can detect about the Mac's display + runtime into
/// good graphics defaults. Grounded in on-device CS2 measurement: rendering at
/// the logical (Retina-off) resolution and letting MetalFX upscale to native is
/// sharp and nearly free because the GPU sits idle behind the CPU/translation
/// bottleneck.
@Suite("PerformanceAdvisor")
struct PerformanceAdvisorTests {
    private let dxmt = RuntimeDescriptor(
        id: "dxmt",
        displayVersion: "DXMT",
        wineBinaryRelativePath: "w",
        gptk: .none,
        dxmt: .installed(version: "0.80")
    )
    private let gptk = RuntimeDescriptor(
        id: "gptk",
        displayVersion: "GPTK",
        wineBinaryRelativePath: "w",
        gptk: .installed(version: "3.0")
    )

    /// A 4K panel shown at "looks like 1080p" (2× Retina) on a DXMT runtime:
    /// render at the 1080p logical size (fast) and let MetalFX ×2 upscale to the
    /// native 4K — sharp and cheap because the GPU has headroom.
    @Test func hiDPI4KOnDXMTRendersLowAndUpscales() {
        let hw = HardwareProfile(physicalWidth: 3840, logicalWidth: 1920, refreshHz: 60)
        let rec = PerformanceAdvisor.recommend(for: hw, runtime: dxmt)
        #expect(rec.retinaMode == false)
        #expect(rec.metalFX == true)
        #expect(rec.metalFXUpscaleFactor == 2.0)
        #expect(rec.maxFrameRate == nil)
    }

    /// A 1.5× scaled display picks the 1.5 factor so the upscaled output still
    /// matches the panel exactly.
    @Test func scaled15OnDXMTUsesFactor15() {
        let hw = HardwareProfile(physicalWidth: 3840, logicalWidth: 2560, refreshHz: 60)
        let rec = PerformanceAdvisor.recommend(for: hw, runtime: dxmt)
        #expect(rec.metalFX == true)
        #expect(rec.metalFXUpscaleFactor == 1.5)
    }

    /// A non-HiDPI display (logical == physical) has nothing to upscale from, so
    /// MetalFX stays off. With no MetalFX to restore sharpness, Retina is left at
    /// the caller's setting rather than forced off (on a 1× panel it's a no-op
    /// anyway).
    @Test func nonHiDPIDisplayLeavesMetalFXOff() {
        let hw = HardwareProfile(physicalWidth: 1920, logicalWidth: 1920, refreshHz: 60)
        let rec = PerformanceAdvisor.recommend(for: hw, runtime: dxmt)
        #expect(rec.retinaMode == true)
        #expect(rec.metalFX == false)
        #expect(rec.metalFXUpscaleFactor == nil)
    }

    /// GPTK runtimes don't use DXMT's spatial upscaler; MetalFX there is DLSS
    /// conversion (game-specific + mutates the shared runtime), so it isn't a
    /// default recommendation. Crucially, without MetalFX to recover sharpness
    /// Retina is left ON — turning it off would render at low resolution with
    /// nothing to upscale it back, degrading the default image quality.
    @Test func gptkRuntimeKeepsRetinaAndMetalFXOff() {
        let hw = HardwareProfile(physicalWidth: 3840, logicalWidth: 1920, refreshHz: 60)
        let rec = PerformanceAdvisor.recommend(for: hw, runtime: gptk)
        #expect(rec.retinaMode == true)
        #expect(rec.metalFX == false)
        #expect(rec.metalFXUpscaleFactor == nil)
    }

    /// The advisor only touches the display-driven graphics fields; unrelated
    /// settings on the base pass through unchanged.
    @Test func preservesUnrelatedBaseSettings() {
        let hw = HardwareProfile(physicalWidth: 3840, logicalWidth: 1920, refreshHz: 60)
        var base = BottleSettings()
        base.sync = .msync
        base.advertiseAVX = true
        base.extraEnvironment = ["FOO": "bar"]
        let rec = PerformanceAdvisor.recommend(for: hw, runtime: dxmt, base: base)
        #expect(rec.sync == .msync)
        #expect(rec.advertiseAVX == true)
        #expect(rec.extraEnvironment == ["FOO": "bar"])
    }

    /// The frame-rate cap is not a display-driven field — the UI's "Recommend"
    /// help promises only Retina/MetalFX changes, so a cap the user set by hand
    /// must survive the recommendation instead of being silently reset to
    /// uncapped. (A new bottle's base is already uncapped, so defaults are
    /// unaffected.)
    @Test func preservesUserFrameRateCap() {
        let hw = HardwareProfile(physicalWidth: 3840, logicalWidth: 1920, refreshHz: 60)
        var base = BottleSettings()
        base.maxFrameRate = 60
        let rec = PerformanceAdvisor.recommend(for: hw, runtime: dxmt, base: base)
        #expect(rec.maxFrameRate == 60)
    }
}
