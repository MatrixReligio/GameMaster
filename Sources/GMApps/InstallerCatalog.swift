import Foundation
import GMModel

/// Data-driven catalog of one-click installable Windows programs. Adding a
/// launcher (Epic, GOG, …) is a JSON edit, not a code change.
public struct InstallerCatalog: Codable, Sendable, Equatable {
    public struct ConfigFile: Codable, Sendable, Equatable {
        public var windowsPath: String
        public var contents: String
    }

    /// Runs the freshly-installed program once (under the install runtime) and
    /// waits for a file to appear before the install is considered complete.
    /// Steam needs this: its first launch downloads the real client (steamui.dll,
    /// CEF, …), and that first bootstrap must happen on a runtime whose 32-bit
    /// support works — modern Wine's new WoW64 crashes Steam's 32-bit
    /// steamservice.exe before the download finishes.
    public struct Bootstrap: Codable, Sendable, Equatable {
        public var readyWindowsPath: String
        public var readyMinBytes: Int
        public var timeoutSeconds: Int
        /// Arguments for the first-run bootstrap launch, when they must differ
        /// from the entry's regular `launchArguments`. Steam needs this:
        /// `-noverifyfiles` (a day-to-day startup speedup) makes the
        /// bootstrapper skip installation verification — but on a fresh
        /// install verification IS what triggers the client download, so
        /// skipping it kills steam.exe with "Failed to load steamui.dll".
        public var launchArguments: [String]?

        public init(
            readyWindowsPath: String,
            readyMinBytes: Int,
            timeoutSeconds: Int,
            launchArguments: [String]? = nil
        ) {
            self.readyWindowsPath = readyWindowsPath
            self.readyMinBytes = readyMinBytes
            self.timeoutSeconds = timeoutSeconds
            self.launchArguments = launchArguments
        }
    }

    /// Replaces Steam's CEF web-helper with a small wrapper that injects
    /// software-rendering flags. Without it, steamwebhelper's GPU compositor
    /// never completes under Wine and the Steam UI stays black.
    public struct WebHelperWrapper: Codable, Sendable, Equatable {
        public var cefWindowsDirectory: String
        public var helperFileName: String
        public var realHelperFileName: String
        public var wrapperResourceName: String

        public init(
            cefWindowsDirectory: String,
            helperFileName: String,
            realHelperFileName: String,
            wrapperResourceName: String
        ) {
            self.cefWindowsDirectory = cefWindowsDirectory
            self.helperFileName = helperFileName
            self.realHelperFileName = realHelperFileName
            self.wrapperResourceName = wrapperResourceName
        }
    }

    /// Replaces Steam's 32-bit `steamservice.exe` with a no-op stub. The real
    /// service null-derefs under modern Wine's new WoW64, popping a "Steam
    /// Service Error" dialog every launch; it's only needed for elevated installs,
    /// not login/downloads, so a do-nothing stub silences the dialog.
    public struct ServiceStub: Codable, Sendable, Equatable {
        public var windowsPaths: [String]
        public var stubResourceName: String

        public init(windowsPaths: [String], stubResourceName: String) {
            self.windowsPaths = windowsPaths
            self.stubResourceName = stubResourceName
        }
    }

    /// Bottle-settings tuning applied when the bottle switches to the entry's
    /// run runtime. Lets the catalog pick the fastest configuration that
    /// runtime supports (e.g. msync on CrossOver-derived builds).
    public struct RunTuning: Codable, Sendable, Equatable {
        public var sync: SyncMode?
        public var advertiseAVX: Bool?

        public init(sync: SyncMode? = nil, advertiseAVX: Bool? = nil) {
            self.sync = sync
            self.advertiseAVX = advertiseAVX
        }
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
        /// Optional first-run bootstrap the installer performs before finishing.
        /// Absent keys decode to nil via the synthesized `Decodable`.
        public var bootstrap: Bootstrap?
        /// Optional CEF web-helper wrapper to install after bootstrapping.
        public var webhelperWrapper: WebHelperWrapper?
        /// Optional no-op replacement for a crashing 32-bit helper service.
        public var serviceStub: ServiceStub?
        /// Runtime to switch the bottle to once installed + bootstrapped. Steam
        /// installs/bootstraps under the bottle's default (GPTK) runtime but
        /// runs under a newer Wine whose CEF handshake actually works.
        public var runRuntimeID: String?
        /// Optional bottle tuning applied together with `runRuntimeID`.
        public var runTuning: RunTuning?

        public init(
            id: String,
            name: String,
            downloadURL: URL,
            installerFileName: String,
            silentArguments: [String],
            installedWindowsPath: String,
            launchArguments: [String],
            configFiles: [ConfigFile] = [],
            bootstrap: Bootstrap? = nil,
            webhelperWrapper: WebHelperWrapper? = nil,
            serviceStub: ServiceStub? = nil,
            runRuntimeID: String? = nil,
            runTuning: RunTuning? = nil
        ) {
            self.id = id
            self.name = name
            self.downloadURL = downloadURL
            self.installerFileName = installerFileName
            self.silentArguments = silentArguments
            self.installedWindowsPath = installedWindowsPath
            self.launchArguments = launchArguments
            self.configFiles = configFiles
            self.bootstrap = bootstrap
            self.webhelperWrapper = webhelperWrapper
            self.serviceStub = serviceStub
            self.runRuntimeID = runRuntimeID
            self.runTuning = runTuning
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static func bundled() throws -> InstallerCatalog {
        guard let url = Bundle.module.url(forResource: "installer-catalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(InstallerCatalog.self, from: Data(contentsOf: url))
    }
}
