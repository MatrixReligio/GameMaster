import GMApps
import GMModel
import SwiftUI

/// A small ⓘ button that reveals a plain-language explanation of an expert
/// setting in a popover, so the sheet stays scannable.
struct InfoButton: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(width: 300, alignment: .leading)
        }
    }
}

/// Per-bottle settings: sensible defaults up front, expert knobs tucked into
/// a disclosure group (progressive disclosure, HIG-style).
struct BottleSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Bottle
    @State private var extraEnvText: String
    /// DXMT ships as wine builtins — no setting can disable it, so the "Off"
    /// choice is hidden for DXMT bottles instead of silently doing nothing.
    @State private var runtimeUsesDXMT = false

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
                Section(String(localized: "Name")) {
                    TextField(String(localized: "Bottle name"), text: $draft.name)
                }

                Section(String(localized: "Display")) {
                    HStack {
                        Toggle(String(localized: "Retina resolution"), isOn: $draft.settings.retinaMode)
                        InfoButton(text: SettingsHelp.retina)
                    }
                }

                Section(String(localized: "Graphics")) {
                    HStack {
                        Picker(String(localized: "DirectX translation"), selection: $draft.settings.dxBackend) {
                            Text(String(localized: "Automatic (recommended)")).tag(DXBackend.auto)
                            if !runtimeUsesDXMT {
                                Text(String(localized: "Off")).tag(DXBackend.off)
                            }
                        }
                        InfoButton(text: runtimeUsesDXMT ? SettingsHelp.directXDXMT : SettingsHelp.directX)
                    }
                    HStack {
                        Toggle(String(localized: "MetalFX upscaling"), isOn: $draft.settings.metalFX)
                        InfoButton(text: SettingsHelp.metalFX)
                    }
                }

                Section(String(localized: "Performance")) {
                    HStack {
                        Picker(String(localized: "Synchronization"), selection: $draft.settings.sync) {
                            Text(String(localized: "MSync (fastest)")).tag(SyncMode.msync)
                            Text(String(localized: "ESync (default)")).tag(SyncMode.esync)
                            Text(String(localized: "None")).tag(SyncMode.none)
                        }
                        InfoButton(text: SettingsHelp.sync)
                    }
                }

                Section {
                    DisclosureGroup(String(localized: "Advanced")) {
                        HStack {
                            Toggle(String(localized: "Metal performance HUD"), isOn: $draft.settings.metalHUD)
                            InfoButton(text: SettingsHelp.metalHUD)
                        }
                        HStack {
                            Toggle(String(localized: "Advertise AVX support"), isOn: $draft.settings.advertiseAVX)
                            InfoButton(text: SettingsHelp.avx)
                        }
                        HStack {
                            Picker(String(localized: "Ray tracing (DXR)"), selection: dxrBinding) {
                                Text(String(localized: "Automatic")).tag(0)
                                Text(String(localized: "On")).tag(1)
                                Text(String(localized: "Off")).tag(2)
                            }
                            InfoButton(text: SettingsHelp.dxr)
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
        .task {
            runtimeUsesDXMT = await appState.bottleUsesDXMTRuntime(draft)
            // A saved-but-ineffective Off from before the option was hidden
            // (or from a runtime switch) is normalized back to Automatic.
            if runtimeUsesDXMT, draft.settings.dxBackend == .off {
                draft.settings.dxBackend = .auto
            }
        }
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
        // Field-level save: the sheet owns name + settings only. A whole-Bottle
        // save would clobber programs/runtime changes (e.g. a finishing install)
        // made while the sheet was open on its stale draft.
        let id = draft.id
        let name = draft.name
        let settings = draft.settings
        Task {
            await appState.updateBottle(id: id, name: name, settings: settings)
            dismiss()
        }
    }
}

// swiftlint:disable line_length
/// Explanations shown by the ⓘ buttons. Long localized literals live here
/// so the view body stays readable; the strings are the localization keys
/// and must not be wrapped.
private enum SettingsHelp {
    static let retina =
        String(
            localized: "Renders at full HiDPI pixel density with matching Windows DPI. Sharper picture, but games draw up to 4× the pixels — turn it off for extra FPS."
        )
    static let directX =
        String(
            localized: "Automatic routes Direct3D through the runtime's D3DMetal layer. Off disables it and falls back to Wine's OpenGL path — only useful for troubleshooting."
        )
    static let directXDXMT =
        String(
            localized: "This bottle's runtime translates Direct3D to Metal with DXMT, which is built into Wine itself and is always active — that's why there is no Off choice here."
        )
    static let metalFX =
        String(
            localized: "Renders internally at a lower resolution and upscales the output with MetalFX. Big FPS gain for a small sharpness cost. Uses DXMT's spatial upscaler, or converts DLSS calls on GPTK runtimes."
        )
    static let sync =
        String(
            localized: "How Wine emulates Windows thread synchronization. MSync (Mach ports) is fastest on runtimes that support it; ESync works everywhere; None is slowest and only for debugging."
        )
    static let metalHUD =
        String(
            localized: "Shows Apple's Metal performance HUD (FPS, GPU time, resolution) over every window in this bottle."
        )
    static let avx =
        String(
            localized: "Advertises AVX/AVX2 CPU support so games pick their optimized code paths (Rosetta translates AVX on macOS 15+). Disable if a game probes AVX-512 and crashes at launch."
        )
    static let dxr =
        String(
            localized: "Forces DirectX Raytracing on or off for D3DMetal (GPTK runtimes only). Automatic follows Apple's default: off on M1/M2, on for M3 and newer."
        )
}

// swiftlint:enable line_length
