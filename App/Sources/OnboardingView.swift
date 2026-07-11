import GMApps
import GMRuntime
import SwiftUI

/// Three-step first-run wizard: welcome/Rosetta → runtime download → GPTK.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .welcome
    @State private var rosettaMissing = false

    enum Step {
        case welcome, runtime, gptk
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 520, height: 440)
        .interactiveDismissDisabled(appState.needsOnboarding && step != .gptk)
        .task {
            rosettaMissing = await !appState.rosettaInstalled()
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 16) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text(String(localized: "Welcome to GameMaster"))
                    .font(.largeTitle.bold())
                Text(
                    String(
                        // swiftlint:disable:next line_length
                        localized: "Play Windows games on your Mac. GameMaster sets up everything for you — no command line, no configuration files."
                    )
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                if rosettaMissing {
                    GroupBox {
                        Label {
                            Text(
                                String(
                                    // swiftlint:disable:next line_length
                                    localized: "Rosetta 2 is required. Run “softwareupdate --install-rosetta” in Terminal first."
                                )
                            )
                            .font(.callout)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            }
        case .runtime:
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text(String(localized: "Install the Windows Runtime"))
                    .font(.title.bold())
                Text(
                    String(
                        // swiftlint:disable:next line_length
                        localized: "GameMaster downloads an open-source Windows compatibility runtime (about 240 MB) with Apple's DirectX translation support built in."
                    )
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                switch appState.runtimeStatus {
                case let .installing(phase, fraction):
                    ProgressView(value: fraction) {
                        Text(phase.localizedTitle)
                    }
                    .frame(width: 280)
                case .ready:
                    Label(String(localized: "Runtime installed"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .missing:
                    Button {
                        Task { await appState.installDefaultRuntime() }
                    } label: {
                        Text(String(localized: "Download and Install"))
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        case .gptk:
            GPTKImportPanel()
        }
    }

    private var footer: some View {
        HStack {
            if step == .gptk {
                Button(String(localized: "Skip for Now")) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch step {
            case .welcome:
                Button(String(localized: "Continue")) { step = .runtime }
                    .buttonStyle(.borderedProminent)
            case .runtime:
                Button(String(localized: "Continue")) { step = .gptk }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.needsOnboarding)
            case .gptk:
                Button(String(localized: "Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Guides the user through the optional D3DMetal refresh from Apple's DMG.
/// Also used in Settings → Runtime.
struct GPTKImportPanel: View {
    @Environment(AppState.self) private var appState
    @State private var showPicker = false
    @State private var importing = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(String(localized: "Update Apple's Graphics Layer (Optional)"))
                .font(.title2.bold())
            Text(
                String(
                    // swiftlint:disable:next line_length
                    localized: "Your runtime already includes DirectX 11/12 translation. To update it to Apple's latest version, download “Evaluation environment for Windows games” from Apple (free Apple ID required) and import the DMG here."
                )
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .font(.callout)

            if case let .ready(gptk) = appState.runtimeStatus, case let .installed(version) = gptk {
                Label(
                    String(localized: "D3DMetal \(version) active"),
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
            }

            if importing {
                ProgressView()
            } else {
                HStack {
                    Button(String(localized: "Open Apple Downloads Page")) {
                        NSWorkspace.shared.open(
                            URL(string: "https://developer.apple.com/download/all/?q=evaluation%20environment")
                                ?? URL(fileURLWithPath: "/")
                        )
                    }
                    Button(String(localized: "Import DMG…")) {
                        detectOrPick()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.diskImage],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let dmg = urls.first {
                importing = true
                Task {
                    await appState.importGPTK(dmg: dmg)
                    importing = false
                }
            }
        }
    }

    /// Prefer auto-detected candidates (mounted volume, then ~/Downloads DMG)
    /// so most users never see a file picker.
    private func detectOrPick() {
        if let volume = appState.gptkDetector.candidateMountedVolumes().first {
            importing = true
            Task {
                await appState.importGPTK(mountedVolume: volume)
                importing = false
            }
        } else if let dmg = appState.gptkDetector.candidateDMGs().first {
            importing = true
            Task {
                await appState.importGPTK(dmg: dmg)
                importing = false
            }
        } else {
            showPicker = true
        }
    }
}
