import GMApps
import Sparkle
import SwiftUI

@main
struct GameMasterApp: App {
    @State private var appState = AppState()

    /// Sparkle auto-update (appcast on GitHub Releases, EdDSA-signed).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    await appState.refresh()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// "Check for Updates…" menu item that reflects Sparkle's canCheckForUpdates.
struct CheckForUpdatesView: View {
    @State private var canCheck = false
    let updater: SPUUpdater

    var body: some View {
        Button(String(localized: "Check for Updates…")) {
            updater.checkForUpdates()
        }
        .disabled(!canCheck)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}
