import Foundation

/// Data-driven catalog of one-click installable Windows programs. Adding a
/// launcher (Epic, GOG, …) is a JSON edit, not a code change.
public struct InstallerCatalog: Codable, Sendable, Equatable {
    public struct ConfigFile: Codable, Sendable, Equatable {
        public var windowsPath: String
        public var contents: String
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var downloadURL: URL
        public var installerFileName: String
        public var silentArguments: [String]
        public var installedWindowsPath: String
        public var launchArguments: [String]
        public var configFiles: [ConfigFile]
    }

    public var entries: [Entry]

    public static func bundled() throws -> InstallerCatalog {
        guard let url = Bundle.module.url(forResource: "installer-catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(InstallerCatalog.self, from: Data(contentsOf: url))
    }
}
