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
        if bottle.settings.metalFX {
            env["D3DM_ENABLE_METALFX"] = "1"
        }

        env.merge(bottle.settings.extraEnvironment) { _, user in user }
        return env
    }
}
