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
    /// DXMT MetalFX spatial upscale factor (`d3d11.metalSpatialUpscaleFactor`):
    /// the game's rendered frame is enlarged by this factor to fill the display.
    /// nil = the runtime's own default (2.0); only used on DXMT runtimes with
    /// MetalFX on.
    public var metalFXUpscaleFactor: Double?
    /// DXMT frame-rate limit (`d3d11.preferredMaxFrameRate`), paced by Metal.
    /// nil = uncapped. DXMT runtimes only.
    public var maxFrameRate: Int?
    public var extraEnvironment: [String: String]

    public init(
        dxBackend: DXBackend = .auto,
        retinaMode: Bool = true,
        sync: SyncMode = .esync,
        metalHUD: Bool = false,
        advertiseAVX: Bool = false,
        dxrOverride: Bool? = nil,
        metalFX: Bool = false,
        metalFXUpscaleFactor: Double? = nil,
        maxFrameRate: Int? = nil,
        extraEnvironment: [String: String] = [:]
    ) {
        self.dxBackend = dxBackend
        self.retinaMode = retinaMode
        self.sync = sync
        self.metalHUD = metalHUD
        self.advertiseAVX = advertiseAVX
        self.dxrOverride = dxrOverride
        self.metalFX = metalFX
        self.metalFXUpscaleFactor = metalFXUpscaleFactor
        self.maxFrameRate = maxFrameRate
        self.extraEnvironment = extraEnvironment
    }

    /// Forward-compatible decoding: bottles written by future app versions may
    /// carry unknown keys or unknown enum raw values; fall back to defaults
    /// rather than failing the whole bottle.
    private enum CodingKeys: String, CodingKey {
        case dxBackend, retinaMode, sync, metalHUD, advertiseAVX, dxrOverride, metalFX
        case metalFXUpscaleFactor, maxFrameRate, extraEnvironment
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
        // Absent on bottles written before these knobs existed → nil = runtime default.
        // A hand-edited bottle.json could carry a non-finite or absurd factor;
        // sanitize it here so no persisted value can later trap `Int(factor)`
        // when it is folded into DXMT_CONFIG.
        metalFXUpscaleFactor = try Self.sanitizedUpscaleFactor(
            container.decodeIfPresent(Double.self, forKey: .metalFXUpscaleFactor)
        )
        maxFrameRate = try container.decodeIfPresent(Int.self, forKey: .maxFrameRate)
        extraEnvironment = try container.decodeIfPresent([String: String].self, forKey: .extraEnvironment) ?? [:]
    }

    /// The MetalFX spatial upscale factor only makes sense finite and within a
    /// sane band: below 1.0 it would shrink the output, and a huge magnitude is
    /// both useless and unsafe (it later reaches `Int(factor)`). Non-finite →
    /// nil (fall back to the runtime default); finite → clamped to [1.0, 4.0].
    static let upscaleFactorRange = 1.0 ... 4.0
    private static func sanitizedUpscaleFactor(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, upscaleFactorRange.lowerBound), upscaleFactorRange.upperBound)
    }
}
