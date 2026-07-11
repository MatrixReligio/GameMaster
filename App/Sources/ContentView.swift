import GMApps
import GMModel
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showOnboarding = false

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let bottle = selectedBottle {
                BottleDetailView(bottle: bottle)
            } else {
                EmptySelectionView()
            }
        }
        .alert(
            String(localized: "Something Went Wrong"),
            isPresented: Binding(
                get: { appState.lastErrorMessage != nil },
                set: {
                    if !$0 {
                        appState.lastErrorMessage = nil
                    }
                }
            ),
            presenting: appState.lastErrorMessage
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
        }
        .task {
            await appState.refresh()
            showOnboarding = appState.needsOnboarding
        }
    }

    private var selectedBottle: Bottle? {
        appState.bottles.first { $0.id == appState.selectedBottleID }
            ?? appState.bottles.first
    }
}

struct EmptySelectionView: View {
    @Environment(AppState.self) private var appState
    @State private var creating = false

    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "No Bottle Yet"), systemImage: "gamecontroller")
        } description: {
            Text(
                String(
                    // swiftlint:disable:next line_length
                    localized: "Create a bottle — a private Windows environment — to install Steam or run Windows games."
                )
            )
        } actions: {
            Button {
                creating = true
                Task {
                    await appState.createBottle(name: String(localized: "My Games"))
                    creating = false
                }
            } label: {
                if creating {
                    ProgressView().controlSize(.small)
                } else {
                    Text(String(localized: "Create Bottle"))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(creating || appState.needsOnboarding)
        }
    }
}
