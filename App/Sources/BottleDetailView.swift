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
            ToolbarItemGroup {
                Button {
                    showRunPicker = true
                } label: {
                    Label(String(localized: "Run Windows Program…"), systemImage: "play.rectangle")
                }
                .help(String(localized: "Run any Windows .exe or .msi in this bottle"))

                Button {
                    showLogs = true
                } label: {
                    Label(String(localized: "Logs"), systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    showSettings = true
                } label: {
                    Label(String(localized: "Bottle Settings"), systemImage: "slider.horizontal.3")
                }

                Button(role: .destructive) {
                    Task { await appState.stopAll(in: bottle) }
                } label: {
                    Label(String(localized: "Force Stop All"), systemImage: "stop.circle")
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

    private var isRunning: Bool {
        appState.runningIDs.contains(program.id)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.tint.opacity(0.15))
                    .frame(height: 90)
                    .overlay {
                        Text(program.name.prefix(1).uppercased())
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.tint)
                    }
                if isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                        .padding(8)
                }
            }
            Text(program.name)
                .font(.headline)
                .lineLimit(1)
            Button {
                Task { await appState.launch(program: program, in: bottle) }
            } label: {
                Label(
                    isRunning ? String(localized: "Running") : String(localized: "Play"),
                    systemImage: "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button(String(localized: "Remove from Library"), role: .destructive) {
                Task { await appState.removeProgram(id: program.id, from: bottle) }
            }
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
