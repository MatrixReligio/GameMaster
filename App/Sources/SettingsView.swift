import GMApps
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem {
                    Label(String(localized: "General"), systemImage: "gearshape")
                }
            RuntimeSettingsPane()
                .tabItem {
                    Label(String(localized: "Runtime"), systemImage: "gearshape.2")
                }
        }
        .frame(width: 560, height: 420)
    }
}

/// App-wide preferences. The language override writes AppleLanguages, which
/// macOS applies on the next launch — same mechanism as System Settings'
/// per-app language, just reachable from inside the app.
struct GeneralSettingsPane: View {
    /// Raw language codes matching the app's localizations; empty = follow
    /// the system language.
    private static let languages: [(code: String, name: String)] = [
        ("en", "English"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("ja", "日本語"),
        ("ko", "한국어")
    ]

    private static func storedSelection() -> String {
        guard let chosen = UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String else {
            return ""
        }
        return languages.first { chosen.hasPrefix($0.code) }?.code ?? ""
    }

    @State private var selection: String = Self.storedSelection()
    /// What the picker showed when the pane opened; any change needs a relaunch.
    @State private var initialSelection: String = Self.storedSelection()

    private var needsRelaunch: Bool {
        selection != initialSelection
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Language"), selection: $selection) {
                    Text(String(localized: "System Default")).tag("")
                    ForEach(Self.languages, id: \.code) { language in
                        Text(verbatim: language.name).tag(language.code)
                    }
                }
                .onChange(of: selection) { _, newValue in
                    if newValue.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    }
                }
                if needsRelaunch {
                    HStack {
                        Text(String(localized: "GameMaster needs to relaunch for the language change to take effect."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Relaunch")) {
                            relaunch()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Spawns a detached re-open of the app bundle, then terminates. `-n` is
    /// not used so the fresh instance replaces this one cleanly.
    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

struct RuntimeSettingsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            switch appState.runtimeStatus {
            case .missing:
                ContentUnavailableView {
                    Label(String(localized: "Runtime not installed"), systemImage: "exclamationmark.triangle")
                } actions: {
                    Button(String(localized: "Download and Install")) {
                        Task { await appState.installDefaultRuntime() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            case let .installing(phase, fraction):
                ProgressView(value: fraction) {
                    Text(phase.localizedTitle)
                }
                .frame(width: 280)
            case .ready:
                GPTKImportPanel()
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await appState.refresh() }
    }
}
