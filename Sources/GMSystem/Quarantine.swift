import Foundation

public enum Quarantine {
    /// Strips com.apple.quarantine recursively. Downloaded wine binaries carry
    /// the quarantine xattr; Gatekeeper would refuse to exec them otherwise.
    /// Missing attributes are not an error.
    public static func remove(from dir: URL, runner: any ProcessRunning) async throws {
        _ = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", dir.path],
            environment: nil,
            currentDirectory: nil,
            outputLine: nil
        )
    }
}
