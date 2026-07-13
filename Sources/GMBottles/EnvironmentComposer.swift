import Foundation
import GMModel

/// Pure function that turns bottle settings + runtime capabilities into the
/// process environment for wine. Order matters: user extras win last.
public enum EnvironmentComposer {
    /// DLL overrides that route DirectX through Apple's D3DMetal, exactly the
    /// set shipped by the evaluation environment ("n,b" = native then builtin).
    static let d3dMetalOverrides = "d3d9,d3d10core,d3d11,d3d12,d3d12core,dxgi=n,b"

    public static func environment(
        for bottle: Bottle,
        prefix: URL,
        runtime: RuntimeDescriptor
    ) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": prefix.path,
            "WINEDEBUG": "-all"
        ]

        switch bottle.settings.sync {
        case .esync:
            env["WINEESYNC"] = "1"
        case .msync:
            env["WINEMSYNC"] = "1"
        case .none:
            break
        }

        let gptkInstalled = if case .installed = runtime.gptk {
            true
        } else {
            false
        }
        if gptkInstalled, bottle.settings.dxBackend != .off {
            env["WINEDLLOVERRIDES"] = d3dMetalOverrides
        }

        if bottle.settings.metalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }
        if bottle.settings.advertiseAVX {
            env["ROSETTA_ADVERTISE_AVX"] = "1"
        }
        if let dxr = bottle.settings.dxrOverride {
            env["D3DM_SUPPORT_DXR"] = dxr ? "1" : "0"
        }
        // MetalFX upscaling routes through whichever translation layer the
        // runtime uses. It enlarges the *output* to the display resolution with
        // a spatial upscaler — it does NOT lower the game's own render
        // resolution (that's Retina), so on its own it costs a little GPU
        // rather than winning FPS; it pays off by making a lower render
        // resolution look sharp. DXMT reads an env switch; D3DMetal has its own
        // DLSS-to-MetalFX toggle.
        if bottle.settings.metalFX {
            if case .installed = runtime.dxmt {
                env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            } else {
                env["D3DM_ENABLE_METALFX"] = "1"
            }
        }

        env.merge(bottle.settings.extraEnvironment) { _, user in user }
        applyDXMTTuning(&env, settings: bottle.settings, runtime: runtime)
        return env
    }

    /// Folds the structured DXMT knobs (MetalFX factor, frame-rate cap) into
    /// `DXMT_CONFIG`, merged with any value the user hand-wrote in the advanced
    /// field — their explicit keys win, so the escape hatch is never clobbered.
    /// Keys are emitted alphabetically for a deterministic result.
    private static func applyDXMTTuning(
        _ env: inout [String: String],
        settings: BottleSettings,
        runtime: RuntimeDescriptor
    ) {
        guard case .installed = runtime.dxmt else { return }
        var config: [String: String] = [:]
        // The factor only matters while MetalFX is actually upscaling.
        if settings.metalFX, let factor = settings.metalFXUpscaleFactor {
            config["d3d11.metalSpatialUpscaleFactor"] = formatFactor(factor)
        }
        if let cap = settings.maxFrameRate {
            config["d3d11.preferredMaxFrameRate"] = String(cap)
        }
        guard !config.isEmpty else { return }
        for (key, value) in parseDXMTConfig(env["DXMT_CONFIG"]) {
            config[key] = value
        }
        env["DXMT_CONFIG"] = config
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    /// 2.0 → "2", 1.5 → "1.5": integral factors drop the trailing ".0".
    /// `Int(value)` traps outside Int64's range, so only take that path for a
    /// finite, sanely-bounded integral value — persisted factors are already
    /// clamped on decode, this guards the in-memory path too.
    private static func formatFactor(_ value: Double) -> String {
        value.isFinite && value == value.rounded() && abs(value) < 1e15
            ? String(Int(value)) : String(value)
    }

    /// Parses a `key=value;key=value` DXMT_CONFIG string into pairs, skipping
    /// malformed entries.
    private static func parseDXMTConfig(_ raw: String?) -> [(String, String)] {
        guard let raw else { return [] }
        return raw.split(separator: ";").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            return (
                String(kv[0]).trimmingCharacters(in: .whitespaces),
                String(kv[1]).trimmingCharacters(in: .whitespaces)
            )
        }
    }
}
