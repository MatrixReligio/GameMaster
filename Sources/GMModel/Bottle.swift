import Foundation

/// A self-contained Windows environment (Wine prefix + metadata).
public struct Bottle: Codable, Identifiable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Identifier of the installed runtime this bottle uses; nil means
    /// "the default runtime from the manifest".
    public var runtimeID: String?
    public var settings: BottleSettings
    public var programs: [Program]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        runtimeID: String? = nil,
        settings: BottleSettings = BottleSettings(),
        programs: [Program] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        // Whole-second precision: bottle.json stores ISO-8601 dates, which
        // have no fractional seconds; equality must survive a round-trip.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.runtimeID = runtimeID
        self.settings = settings
        self.programs = programs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, createdAt, runtimeID, settings, programs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        runtimeID = try container.decodeIfPresent(String.self, forKey: .runtimeID)
        settings = try container.decodeIfPresent(BottleSettings.self, forKey: .settings) ?? BottleSettings()
        programs = try container.decodeIfPresent([Program].self, forKey: .programs) ?? []
    }
}
