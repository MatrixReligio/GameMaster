import Foundation

/// Stores per-program icons extracted from their executables at
/// `bottles/<uuid>/icons/<program-id>.ico`. Extraction failures are fine —
/// the UI falls back to a monogram card.
public enum ProgramIconStore {
    public static func iconURL(programID: UUID, bottleDirectory: URL) -> URL {
        bottleDirectory
            .appendingPathComponent("icons", isDirectory: true)
            .appendingPathComponent("\(programID.uuidString).ico")
    }

    /// Extracts the exe's icon and stores it for the program. Returns the icon
    /// URL if an icon was produced.
    @discardableResult
    public static func extractAndStore(exe: URL, programID: UUID, bottleDirectory: URL) -> URL? {
        guard let ico = PEIconExtractor.extractIcoData(from: exe) else { return nil }
        let target = iconURL(programID: programID, bottleDirectory: bottleDirectory)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try ico.write(to: target)
            return target
        } catch {
            return nil
        }
    }

    public static func removeIcon(programID: UUID, bottleDirectory: URL) {
        try? FileManager.default.removeItem(
            at: iconURL(programID: programID, bottleDirectory: bottleDirectory)
        )
    }
}
