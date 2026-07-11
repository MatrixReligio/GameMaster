import Foundation

/// Real `ProcessRunning` backed by Foundation.Process.
public struct SubprocessRunner: ProcessRunning {
    public init() {}

    @discardableResult
    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        outputLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Accumulate partial lines across reads; emit only complete lines.
        let lineBuffer = LineBuffer(onLine: outputLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lineBuffer.finish()
            } else {
                lineBuffer.append(data)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                // Drain whatever the readability handler has not seen yet.
                if let handle = (finished.standardOutput as? Pipe)?.fileHandleForReading {
                    handle.readabilityHandler = nil
                    if let rest = try? handle.readToEnd() {
                        lineBuffer.append(rest)
                    }
                    lineBuffer.finish()
                }
                continuation.resume(returning: ProcessResult(exitCode: finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Splits a byte stream into UTF-8 lines. Thread-safe: Pipe callbacks and the
/// termination handler race on different queues.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard onLine != nil else { return }
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            lines.append(Self.decode(lineData))
        }
        lock.unlock()
        for line in lines {
            onLine?(line)
        }
    }

    func finish() {
        guard onLine != nil else { return }
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if !rest.isEmpty {
            onLine?(Self.decode(rest))
        }
    }

    /// Wine output is usually UTF-8 but can contain arbitrary bytes; fall back
    /// to Latin-1, which never fails, rather than dropping the line.
    private static func decode(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }
}
