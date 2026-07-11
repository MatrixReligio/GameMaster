import Foundation

/// A Windows program registered in a bottle's library.
public struct Program: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Windows-style absolute path inside the bottle, e.g.
    /// `C:\Program Files (x86)\Steam\steam.exe`.
    public var windowsPath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var pinned: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        windowsPath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        pinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.windowsPath = windowsPath
        self.arguments = arguments
        self.environment = environment
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, windowsPath, arguments, environment, pinned
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        windowsPath = try container.decode(String.self, forKey: .windowsPath)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}
