import Foundation

/// DirectX translation backend selection for a bottle.
/// `.auto` uses D3DMetal whenever the bottle's runtime has it installed.
public enum DXBackend: String, Codable, Sendable, CaseIterable {
    case auto
    case d3dMetal
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
    public var extraEnvironment: [String: String]

    public init(
        dxBackend: DXBackend = .auto,
        retinaMode: Bool = true,
        sync: SyncMode = .esync,
        metalHUD: Bool = false,
        advertiseAVX: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) {
        self.dxBackend = dxBackend
        self.retinaMode = retinaMode
        self.sync = sync
        self.metalHUD = metalHUD
        self.advertiseAVX = advertiseAVX
        self.extraEnvironment = extraEnvironment
    }

    /// Forward-compatible decoding: bottles written by future app versions may
    /// carry unknown keys or unknown enum raw values; fall back to defaults
    /// rather than failing the whole bottle.
    private enum CodingKeys: String, CodingKey {
        case dxBackend, retinaMode, sync, metalHUD, advertiseAVX, extraEnvironment
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
        extraEnvironment = try container.decodeIfPresent([String: String].self, forKey: .extraEnvironment) ?? [:]
    }
}
