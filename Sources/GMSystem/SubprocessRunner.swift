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

        // No output requested → no pipe. This is not just an optimization:
        // helpers like `wine start /unix` exit immediately while the program
        // they spawned inherits the pipe's write end. Waiting for EOF then
        // blocks until that whole process tree exits (Steam's bootstrap hung
        // "Configuring…" forever this way). With the null device, completion
        // is the helper's termination alone.
        guard outputLine != nil else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: ProcessResult(exitCode: finished.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Accumulate partial lines across reads; emit only complete lines.
        // The readabilityHandler is the SOLE reader of the pipe (the
        // termination handler must never call readToEnd concurrently, or the
        // two reads race and split/drop bytes). We resume the continuation only
        // once BOTH the pipe has reached EOF and the process has terminated, so
        // no trailing output is lost.
        let lineBuffer = LineBuffer(onLine: outputLine)

        return try await withCheckedThrowingContinuation { continuation in
            let completion = CompletionCoordinator { exitCode in
                lineBuffer.finish()
                continuation.resume(returning: ProcessResult(exitCode: exitCode))
            }

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    completion.markEOF()
                } else {
                    lineBuffer.append(data)
                }
            }

            process.terminationHandler = { finished in
                completion.markTerminated(exitCode: finished.terminationStatus)
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

/// Fires `onDone` exactly once, after BOTH the pipe reached EOF and the process
/// terminated (in either order). Thread-safe.
private final class CompletionCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var eof = false
    private var exitCode: Int32?
    private var fired = false
    private let onDone: (Int32) -> Void

    init(onDone: @escaping (Int32) -> Void) {
        self.onDone = onDone
    }

    func markEOF() {
        lock.lock()
        eof = true
        let code = maybeFire()
        lock.unlock()
        if let code {
            onDone(code)
        }
    }

    func markTerminated(exitCode: Int32) {
        lock.lock()
        self.exitCode = exitCode
        let code = maybeFire()
        lock.unlock()
        if let code {
            onDone(code)
        }
    }

    /// Caller must hold the lock. Returns the exit code to fire with, or nil.
    private func maybeFire() -> Int32? {
        guard !fired, eof, let exitCode else { return nil }
        fired = true
        return exitCode
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
