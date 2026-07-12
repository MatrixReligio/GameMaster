import Foundation

/// DirectX translation backend selection for a bottle.
/// `.auto` uses whatever D3D-to-Metal layer the bottle's runtime carries
/// (D3DMetal on GPTK runtimes, DXMT builtins otherwise); `.off` disables
/// D3DMetal's DLL overrides. Bottles saved with the removed `d3dMetal` case
/// decode back to `.auto` via the forward-compatible fallback.
public enum DXBackend: String, Codable, Sendable, CaseIterable {
    case auto
    case off
}

/// Wine synchronization primitive. esync is the safe default; msync is the
/// faster Mach-port variant supported by CrossOver-derived builds.
public enum SyncMode: String, Codable, Sendable, CaseIterable {
    case esync
    case msync
    case none
}

public struct BottleSettings: Codable, Equatable, Sendable {
    public var dxBackend: DXBackend
    public var retinaMode: Bool
    public var sync: SyncMode
    public var metalHUD: Bool
    public var advertiseAVX: Bool
    /// nil = Apple's built-in default (DXR off on M1/M2, on for M3+).
    public var dxrOverride: Bool?
    /// Converts DLSS calls to MetalFX where possible (macOS 26+).
    public var metalFX: Bool
    public var extraEnvironment: [String: String]

    public init(
        dxBackend: DXBackend = .auto,
        retinaMode: Bool = true,
        sync: SyncMode = .esync,
        metalHUD: Bool = false,
        advertiseAVX: Bool = false,
        dxrOverride: Bool? = nil,
        metalFX: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) {
        self.dxBackend = dxBackend
        self.retinaMode = retinaMode
        self.sync = sync
        self.metalHUD = metalHUD
        self.advertiseAVX = advertiseAVX
        self.dxrOverride = dxrOverride
        self.metalFX = metalFX
        self.extraEnvironment = extraEnvironment
    }

    /// Forward-compatible decoding: bottles written by future app versions may
    /// carry unknown keys or unknown enum raw values; fall back to defaults
    /// rather than failing the whole bottle.
    private enum CodingKeys: String, CodingKey {
        case dxBackend, retinaMode, sync, metalHUD, advertiseAVX, dxrOverride, metalFX, extraEnvironment
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let backendRaw = try container.decodeIfPresent(String.self, forKey: .dxBackend)
        dxBackend = backendRaw.flatMap(DXBackend.init(rawValue:)) ?? .auto
        retinaMode = try container.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        let syncRaw = try container.decodeIfPresent(String.self, forKey: .sync)
        sync = syncRaw.flatMap(SyncMode.init(rawValue:)) ?? .esync
        metalHUD = try container.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        advertiseAVX = try container.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? false
        dxrOverride = try container.decodeIfPresent(Bool.self, forKey: .dxrOverride)
        metalFX = try container.decodeIfPresent(Bool.self, forKey: .metalFX) ?? false
        extraEnvironment = try container.decodeIfPresent([String: String].self, forKey: .extraEnvironment) ?? [:]
    }
}
