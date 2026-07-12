import Foundation

/// The set of runtimes GameMaster knows how to download, bundled as a JSON
/// resource so a release pins exact URLs + SHA-256 digests.
public struct RuntimeManifest: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var displayVersion: String
        public var url: URL
        public var sha256: String
        public var wineBinaryRelativePath: String
        /// Version of Apple's evaluation layers shipped inside this runtime
        /// build, if any (the Gcenx GPTK builds include them).
        public var bundledGPTKVersion: String?
        /// Version of DXMT (D3D 10/11 → Metal) preinstalled as wine builtins
        /// in this runtime build, if any (see scripts/assemble-steam-runtime.sh).
        public var bundledDXMTVersion: String?

        public init(
            id: String,
            displayVersion: String,
            url: URL,
            sha256: String,
            wineBinaryRelativePath: String,
            bundledGPTKVersion: String?,
            bundledDXMTVersion: String? = nil
        ) {
            self.id = id
            self.displayVersion = displayVersion
            self.url = url
            self.sha256 = sha256
            self.wineBinaryRelativePath = wineBinaryRelativePath
            self.bundledGPTKVersion = bundledGPTKVersion
            self.bundledDXMTVersion = bundledDXMTVersion
        }
    }

    public var defaultRuntimeID: String
    public var entries: [Entry]

    public init(defaultRuntimeID: String, entries: [Entry]) {
        self.defaultRuntimeID = defaultRuntimeID
        self.entries = entries
    }

    public var defaultEntry: Entry? {
        entries.first { $0.id == defaultRuntimeID }
    }

    public static func bundled() throws -> RuntimeManifest {
        guard let url = Bundle.module.url(forResource: "runtime-manifest", withExtension: "json") else {
            throw RuntimeError.manifestMissing
        }
        return try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: url))
    }
}
