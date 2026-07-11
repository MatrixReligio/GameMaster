import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32

    public init(exitCode: Int32) {
        self.exitCode = exitCode
    }
}

/// Abstraction over launching external processes so that every consumer can
/// be tested with a scripted fake.
public protocol ProcessRunning: Sendable {
    /// Launches a process and waits for it to exit. stdout and stderr are
    /// merged and delivered line-by-line to `outputLine`. When `environment`
    /// is non-nil it is merged over the inherited environment (PATH etc.
    /// must survive — wine cannot run in an empty environment).
    @discardableResult
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        outputLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult
}
