import GMApps
import GMModel
import SwiftUI

/// Per-bottle settings: sensible defaults up front, expert knobs tucked into
/// a disclosure group (progressive disclosure, HIG-style).
struct BottleSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Bottle
    @State private var extraEnvText: String

    init(bottle: Bottle) {
        _draft = State(initialValue: bottle)
        _extraEnvText = State(initialValue: bottle.settings.extraEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Display")) {
                    Toggle(String(localized: "Retina resolution"), isOn: $draft.settings.retinaMode)
                        .help(String(localized: "Render at full pixel density on HiDPI displays"))
                }

                Section(String(localized: "Graphics")) {
                    Picker(String(localized: "DirectX translation"), selection: $draft.settings.dxBackend) {
                        Text(String(localized: "Automatic (recommended)")).tag(DXBackend.auto)
                        Text(String(localized: "Off")).tag(DXBackend.off)
                    }
                    Toggle(String(localized: "MetalFX upscaling (DLSS games)"), isOn: $draft.settings.metalFX)
                }

                Section(String(localized: "Performance")) {
                    Picker(String(localized: "Synchronization"), selection: $draft.settings.sync) {
                        Text(String(localized: "ESync (default)")).tag(SyncMode.esync)
                        Text(String(localized: "MSync (faster, experimental)")).tag(SyncMode.msync)
                        Text(String(localized: "None")).tag(SyncMode.none)
                    }
                }

                Section {
                    DisclosureGroup(String(localized: "Advanced")) {
                        Toggle(String(localized: "Metal performance HUD"), isOn: $draft.settings.metalHUD)
                        Toggle(String(localized: "Advertise AVX support"), isOn: $draft.settings.advertiseAVX)
                        Picker(String(localized: "Ray tracing (DXR)"), selection: dxrBinding) {
                            Text(String(localized: "Automatic")).tag(0)
                            Text(String(localized: "On")).tag(1)
                            Text(String(localized: "Off")).tag(2)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "Environment variables (one per line, KEY=value)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $extraEnvText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 64)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                Button(String(localized: "Save")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 480)
    }

    private var dxrBinding: Binding<Int> {
        Binding(
            get: {
                switch draft.settings.dxrOverride {
                case nil: 0
                case true?: 1
                case false?: 2
                }
            },
            set: { value in
                draft.settings.dxrOverride = value == 0 ? nil : value == 1
            }
        )
    }

    private func save() {
        var env: [String: String] = [:]
        for line in extraEnvText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            env[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        draft.settings.extraEnvironment = env
        let updated = draft
        Task {
            await appState.updateBottle(updated)
            dismiss()
        }
    }
}
