import Foundation

public enum ArchiveError: Error, LocalizedError, Equatable {
    case extractionFailed(exitCode: Int32)

    public var errorDescription: String? {
        switch self {
        case let .extractionFailed(code):
            String(localized: "Could not unpack the archive (tar exit \(code)).")
        }
    }
}

public enum Archive {
    /// Extracts a tarball (gz/xz auto-detected by bsdtar) preserving symlinks
    /// and permissions.
    public static func extractTar(_ archive: URL, into dir: URL, runner: any ProcessRunning) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xf", archive.path, "-C", dir.path],
            environment: nil,
            currentDirectory: nil,
            outputLine: nil
        )
        guard result.exitCode == 0 else {
            throw ArchiveError.extractionFailed(exitCode: result.exitCode)
        }
    }
}
