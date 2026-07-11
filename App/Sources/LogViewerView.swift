import GMApps
import GMModel
import SwiftUI

/// Read-only viewer over the bottle's launch logs.
struct LogViewerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle

    @State private var logFiles: [URL] = []
    @State private var selected: URL?
    @State private var content = ""

    var body: some View {
        NavigationSplitView {
            List(logFiles, id: \.self, selection: $selected) { file in
                Text(file.deletingPathExtension().lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(minWidth: 200)
        } detail: {
            if content.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Logs Yet"),
                    systemImage: "doc.text",
                    description: Text(String(localized: "Launch a program and its output will appear here."))
                )
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .frame(width: 720, height: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Close")) { dismiss() }
            }
            ToolbarItem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [selected ?? logsDirectory].compactMap(\.self)
                    )
                } label: {
                    Label(String(localized: "Show in Finder"), systemImage: "folder")
                }
            }
        }
        .task(id: selected) {
            if let selected {
                content = (try? String(contentsOf: selected, encoding: .utf8)) ?? ""
            }
        }
        .task {
            reload()
        }
    }

    private var logsDirectory: URL {
        appState.logsRoot.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        logFiles = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        selected = logFiles.first
    }
}
