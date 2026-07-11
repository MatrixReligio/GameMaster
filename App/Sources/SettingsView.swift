import GMApps
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            RuntimeSettingsPane()
                .tabItem {
                    Label(String(localized: "Runtime"), systemImage: "gearshape.2")
                }
        }
        .frame(width: 560, height: 420)
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
