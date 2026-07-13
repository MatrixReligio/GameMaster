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
    @State private var advancedExpanded = false

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
                    HStack {
                        Button(String(localized: "Recommend for this Mac")) { applyRecommendation() }
                        InfoButton(text: SettingsHelp.recommend)
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
                    // DXMT-only tuning: the factor and frame cap are DXMT_CONFIG
                    // keys, so they'd do nothing on a D3DMetal (GPTK) bottle.
                    if runtimeUsesDXMT {
                        if draft.settings.metalFX {
                            HStack {
                                Picker(
                                    String(localized: "MetalFX quality"),
                                    selection: $draft.settings.metalFXUpscaleFactor
                                ) {
                                    Text(String(localized: "Default")).tag(Double?.none)
                                    Text(verbatim: "1.5×").tag(Double?(1.5))
                                    Text(verbatim: "2.0×").tag(Double?(2.0))
                                }
                                InfoButton(text: SettingsHelp.metalFXQuality)
                            }
                        }
                        HStack {
                            Picker(
                                String(localized: "Frame rate limit"),
                                selection: $draft.settings.maxFrameRate
                            ) {
                                Text(String(localized: "Uncapped")).tag(Int?.none)
                                Text(verbatim: "60").tag(Int?(60))
                                Text(verbatim: "120").tag(Int?(120))
                                Text(verbatim: "240").tag(Int?(240))
                            }
                            InfoButton(text: SettingsHelp.frameRate)
                        }
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
                    DisclosureGroup(isExpanded: $advancedExpanded) {
                        HStack {
                            Toggle(String(localized: "Metal performance HUD"), isOn: $draft.settings.metalHUD)
                            InfoButton(text: SettingsHelp.metalHUD)
                        }
                        .padding(.vertical, 4)
                        HStack {
                            Toggle(String(localized: "Advertise AVX support"), isOn: $draft.settings.advertiseAVX)
                            InfoButton(text: SettingsHelp.avx)
                        }
                        .padding(.vertical, 4)
                        HStack {
                            Picker(String(localized: "Ray tracing (DXR)"), selection: dxrBinding) {
                                Text(String(localized: "Automatic")).tag(0)
                                Text(String(localized: "On")).tag(1)
                                Text(String(localized: "Off")).tag(2)
                            }
                            InfoButton(text: SettingsHelp.dxr)
                        }
                        .padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(String(localized: "Environment variables (one per line, KEY=value)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $extraEnvText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 64)
                        }
                        .padding(.vertical, 6)
                    } label: {
                        // Full-width, tappable header: the bare DisclosureGroup
                        // label only toggles on the chevron itself — a tiny
                        // target users kept missing.
                        Text(String(localized: "Advanced"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation { advancedExpanded.toggle() }
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

    /// Fills the draft with settings tuned to this Mac's display. Only the draft
    /// changes; the bottle is written when the user taps Save, so existing
    /// bottles are never altered behind their back.
    private func applyRecommendation() {
        Task {
            if let recommended = await appState.recommendedSettings(for: draft) {
                draft.settings = recommended
            }
        }
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
        // Close immediately: the save itself is instant file I/O, but a
        // Retina change re-runs wine's regedit, which can cold-boot the
        // prefix for seconds — the sheet must not sit frozen through that.
        // Errors still surface via lastErrorMessage in the main window.
        dismiss()
        Task {
            await appState.updateBottle(id: id, name: name, settings: settings)
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
            localized: "Enlarges the game's rendered frame to your display resolution with MetalFX — a spatial upscaler that looks sharper than plain stretching, for a small GPU cost. It does NOT lower the game's own resolution (that's Retina); it makes a lower render resolution look crisp. Best with Retina off. Uses DXMT's upscaler, or converts DLSS on GPTK runtimes."
        )
    static let metalFXQuality =
        String(
            localized: "How far MetalFX enlarges the frame. A higher factor means the game renders smaller — faster, but softer. 2.0× renders at half your display's width; 1.5× renders closer to native (sharper, heavier). Default (2.0×) follows the runtime."
        )
    static let frameRate =
        String(
            localized: "Caps the frame rate, paced by Metal for steadier frame times. Pick a value your Mac can hold steady — ideally a divisor of your display's refresh rate. Uncapped gives the lowest input lag (best for competitive games) at the cost of more heat and fan noise."
        )
    static let recommend =
        String(
            localized: "Sets Retina, MetalFX and the upscale factor to values matched to this Mac's display. Nothing is applied until you tap Save, so it never changes a bottle behind your back."
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
