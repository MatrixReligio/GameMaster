import CoreGraphics
import GMApps
import GMModel
import GMRuntime
import SwiftUI
import UniformTypeIdentifiers

struct BottleDetailView: View {
    @Environment(AppState.self) private var appState
    let bottle: Bottle

    @State private var showSettings = false
    @State private var showLogs = false
    @State private var showRunPicker = false
    @State private var droppedExe: URL?

    private var pinnedPrograms: [Program] {
        bottle.programs.filter(\.pinned)
    }

    var body: some View {
        Group {
            if bottle.programs.isEmpty {
                emptyState
            } else {
                programGrid
            }
        }
        .navigationTitle(bottle.name)
        .toolbar {
            // Visible titles, not icon-only: the purpose must be readable at
            // a glance — macOS tooltips take over a second to appear and the
            // delay is system-wide, not something the app can shorten.
            ToolbarItemGroup {
                Button {
                    showRunPicker = true
                } label: {
                    Label(String(localized: "Run Program…"), systemImage: "play.rectangle")
                        .labelStyle(.titleAndIcon)
                }
                .help(String(localized: "Run any Windows .exe or .msi in this bottle"))

                Button {
                    showLogs = true
                } label: {
                    Label(String(localized: "Logs"), systemImage: "doc.text.magnifyingglass")
                        .labelStyle(.titleAndIcon)
                }

                Button {
                    showSettings = true
                } label: {
                    Label(String(localized: "Bottle Settings"), systemImage: "slider.horizontal.3")
                        .labelStyle(.titleAndIcon)
                }

                Button(role: .destructive) {
                    Task { await appState.stopAll(in: bottle) }
                } label: {
                    Label(String(localized: "Force Stop All"), systemImage: "stop.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help(String(localized: "Terminate every Windows process in this bottle"))
            }
        }
        .sheet(isPresented: $showSettings) {
            BottleSettingsSheet(bottle: bottle)
        }
        .sheet(isPresented: $showLogs) {
            LogViewerView(bottle: bottle)
        }
        .fileImporter(
            isPresented: $showRunPicker,
            allowedContentTypes: [.exe, .msi],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                droppedExe = url
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isWindowsExecutable) else { return false }
            droppedExe = url
            return true
        }
        .confirmationDialog(
            String(localized: "How do you want to open this program?"),
            isPresented: Binding(
                get: { droppedExe != nil },
                set: {
                    if !$0 {
                        droppedExe = nil
                    }
                }
            ),
            presenting: droppedExe
        ) { exe in
            Button(String(localized: "Run Once")) {
                Task { await appState.runExe(exe, in: bottle) }
            }
            Button(String(localized: "Add to Library and Run")) {
                Task {
                    await appState.addProgram(exe: exe, in: bottle)
                    await appState.runExe(exe, in: bottle)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { exe in
            Text(exe.lastPathComponent)
        }
    }

    static func isWindowsExecutable(_ url: URL) -> Bool {
        ["exe", "msi"].contains(url.pathExtension.lowercased())
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            SteamHeroCard(bottle: bottle)
            Button {
                showRunPicker = true
            } label: {
                Label(String(localized: "Or run another Windows program…"), systemImage: "folder")
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var programGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                ForEach(bottle.programs) { program in
                    ProgramCard(program: program, bottle: bottle)
                }
            }
            .padding()
        }
    }
}

/// One-click Steam install: the hero action of an empty bottle.
struct SteamHeroCard: View {
    @Environment(AppState.self) private var appState
    let bottle: Bottle

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.rain.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(String(localized: "Install Steam for Windows"))
                .font(.title2.bold())
            Text(
                String(
                    // swiftlint:disable:next line_length
                    localized: "Set up the Windows version of Steam with one click, then install and play your Windows games."
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

            if let progress = appState.installProgress {
                VStack(spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 240)
                    Text(progress.phase.localizedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await appState.installCatalogApp(id: "steam", into: bottle) }
                } label: {
                    Text(String(localized: "Install Steam"))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(32)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ProgramCard: View {
    @Environment(AppState.self) private var appState
    let program: Program
    let bottle: Bottle

    @State private var icon: NSImage?

    private var isRunning: Bool {
        // runningIDs ∪ active bottle: after an app relaunch the per-program
        // IDs are gone but the bottle's wineserver may still be alive —
        // showing Play there would launch a second instance.
        appState.isProgramRunning(program, in: bottle)
    }

    private var isMigrating: Bool {
        appState.migratingProgramID == program.id
    }

    private var isLaunching: Bool {
        appState.launchingIDs.contains(program.id)
    }

    private var isClosing: Bool {
        appState.closingIDs.contains(program.id)
    }

    /// Stable, name-derived hue so each fallback card gets its own color.
    private var fallbackGradient: LinearGradient {
        var hash: UInt32 = 5381
        for byte in program.name.utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        let hue = Double(hash % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.60),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.38)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(icon == nil ? AnyShapeStyle(fallbackGradient) : AnyShapeStyle(.quaternary.opacity(0.4)))
                    .frame(height: 90)
                    .overlay {
                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 64, height: 64)
                                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        } else {
                            Text(program.name.prefix(1).uppercased())
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                    }
                if isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                        .padding(8)
                }
            }
            .task(id: program.id) {
                if let url = await appState.iconURL(for: program, in: bottle) {
                    icon = NSImage(contentsOf: url)
                }
            }
            Text(program.name)
                .font(.headline)
                .lineLimit(1)
            if isMigrating, let progress = appState.installProgress {
                VStack(spacing: 4) {
                    ProgressView(value: progress.fraction)
                    Text(String(localized: "Upgrading runtime…"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else if isLaunching || isClosing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(isClosing ? String(localized: "Closing…") : String(localized: "Starting…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else if isRunning {
                Button {
                    Task { await appState.stopProgram(program, in: bottle) }
                } label: {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    Task { await appState.launch(program: program, in: bottle) }
                } label: {
                    Label(String(localized: "Play"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .task(id: isRunning) {
            if isRunning {
                await trackWindowLifecycle()
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button(String(localized: "Remove from Library"), role: .destructive) {
                Task { await appState.removeProgram(id: program.id, from: bottle) }
            }
        }
    }

    /// Drives the Starting… → Running → Closing… states off the Wine window
    /// appearing and then disappearing. Uses window *owner* names only (available
    /// without Screen Recording permission, unlike window titles). Baseline-
    /// relative so a window from another running bottle isn't mistaken for this
    /// program's. The final Running→idle transition is driven by the launch call
    /// returning when the process fully exits.
    private func trackWindowLifecycle() async {
        let baseline = Self.wineWindowCount()
        // Phase 1: wait for this program's window to appear.
        var appeared = false
        for _ in 0 ..< 90 {
            if Task.isCancelled {
                return
            }
            if Self.wineWindowCount() > baseline {
                appeared = true
                appState.markProgramWindowReady(program.id)
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        guard appeared else { return }
        // Phase 2: wait for the window to close (user quit) while the process
        // finishes shutting down. Polled at a relaxed interval: this runs for
        // the entire play session, and a "Closing…" label appearing a couple
        // of seconds late is imperceptible — fewer wakeups while gaming.
        while !Task.isCancelled {
            if Self.wineWindowCount() <= baseline {
                appState.markProgramClosing(program.id)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Count of on-screen windows owned by a Wine process.
    private static func wineWindowCount() -> Int {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        return list.count { info in
            let owner = (info[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            return owner.contains("wine")
        }
    }
}

extension InstallPhase {
    var localizedTitle: String {
        switch self {
        case .downloading: String(localized: "Downloading…")
        case .installing: String(localized: "Installing…")
        case .configuring: String(localized: "Configuring…")
        case .done: String(localized: "Done")
        }
    }
}

extension GMRuntime.RuntimePhase {
    var localizedTitle: String {
        switch self {
        case .downloading: String(localized: "Downloading…")
        case .verifying: String(localized: "Verifying…")
        case .unpacking: String(localized: "Unpacking…")
        case .finishing: String(localized: "Finishing…")
        }
    }
}

extension UTType {
    static let exe = UTType(filenameExtension: "exe") ?? .data
    static let msi = UTType(filenameExtension: "msi") ?? .data
}
