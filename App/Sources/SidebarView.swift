import GMApps
import GMModel
import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var bottleToDelete: Bottle?

    var body: some View {
        @Bindable var appState = appState
        List(selection: $appState.selectedBottleID) {
            Section(String(localized: "Bottles")) {
                ForEach(appState.bottles) { bottle in
                    Label(bottle.name, systemImage: "gamecontroller.fill")
                        .tag(bottle.id)
                        .contextMenu {
                            Button(String(localized: "Delete Bottle…"), role: .destructive) {
                                bottleToDelete = bottle
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            RuntimeStatusChip()
                .padding(10)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await appState.createBottle(name: String(localized: "My Games")) }
                } label: {
                    Label(String(localized: "New Bottle"), systemImage: "plus")
                }
                .disabled(appState.needsOnboarding)
                .help(String(localized: "Create a new Windows environment"))
            }
        }
        .navigationTitle(Text(verbatim: "GameMaster"))
        .confirmationDialog(
            String(localized: "Delete this bottle and everything installed in it?"),
            isPresented: Binding(
                get: { bottleToDelete != nil },
                set: {
                    if !$0 {
                        bottleToDelete = nil
                    }
                }
            ),
            presenting: bottleToDelete
        ) { bottle in
            Button(String(localized: "Delete"), role: .destructive) {
                Task { await appState.deleteBottle(bottle) }
            }
        } message: { bottle in
            Text(String(localized: "“\(bottle.name)” will be moved to oblivion. This cannot be undone."))
        }
    }
}

struct RuntimeStatusChip: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            switch appState.runtimeStatus {
            case .missing:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(String(localized: "Runtime not installed"))
            case let .installing(_, fraction):
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(width: 60)
                Text(String(localized: "Installing runtime…"))
            case let .ready(gptk):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if case let .installed(version) = gptk {
                    Text(String(localized: "D3DMetal \(version) ready"))
                } else {
                    Text(String(localized: "Runtime ready"))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
