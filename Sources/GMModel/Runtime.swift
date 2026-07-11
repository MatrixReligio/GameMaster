import Foundation

/// Whether a runtime carries Apple's D3DMetal evaluation layers, and which
/// version if so.
public enum GPTKStatus: Codable, Equatable, Sendable {
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

    public init(
        id: String,
        displayVersion: String,
        wineBinaryRelativePath: String,
        gptk: GPTKStatus = .none
    ) {
        self.id = id
        self.displayVersion = displayVersion
        self.wineBinaryRelativePath = wineBinaryRelativePath
        self.gptk = gptk
    }
}
