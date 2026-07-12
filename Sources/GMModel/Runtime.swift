import Foundation

/// Whether a runtime carries Apple's D3DMetal evaluation layers, and which
/// version if so.
public enum GPTKStatus: Codable, Equatable, Sendable {
    case none
    case installed(version: String)
}

/// Whether a runtime ships DXMT (Direct3D 10/11 → Metal) as wine builtins,
/// and which version if so. DXMT builtins need no WINEDLLOVERRIDES, but their
/// winemetal.dll bridge must also be mirrored into each prefix's system32.
public enum DXMTStatus: Codable, Equatable, Sendable {
    case none
    case installed(version: String)
}

/// Metadata for one installed Wine runtime, persisted as
/// `runtimes/<id>/runtime.json`.
public struct RuntimeDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayVersion: String
    /// Path of the wine binary relative to the runtime directory.
    public var wineBinaryRelativePath: String
    public var gptk: GPTKStatus
    public var dxmt: DXMTStatus

    public init(
        id: String,
        displayVersion: String,
        wineBinaryRelativePath: String,
        gptk: GPTKStatus = .none,
        dxmt: DXMTStatus = .none
    ) {
        self.id = id
        self.displayVersion = displayVersion
        self.wineBinaryRelativePath = wineBinaryRelativePath
        self.gptk = gptk
        self.dxmt = dxmt
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayVersion, wineBinaryRelativePath, gptk, dxmt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayVersion = try container.decode(String.self, forKey: .displayVersion)
        wineBinaryRelativePath = try container.decode(String.self, forKey: .wineBinaryRelativePath)
        gptk = try container.decode(GPTKStatus.self, forKey: .gptk)
        // runtime.json files written before DXMT existed lack this key; they
        // must keep decoding or installed runtimes vanish from the store.
        dxmt = try container.decodeIfPresent(DXMTStatus.self, forKey: .dxmt) ?? .none
    }
}
