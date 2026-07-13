import Foundation
import GMSystem
import Synchronization

/// Records process invocations and replays a scripted response. Thread-safe.
public final class FakeRunner: ProcessRunning, Sendable {
    public struct Invocation: Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]?

        public init(executable: String, arguments: [String], environment: [String: String]? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
        }
    }

    private struct State {
        var invocations: [Invocation] = []
        var stdoutScripts: [[String]]
        var exitCode: Int32
        var delayNanoseconds: UInt64
    }

    private let state: Mutex<State>

    public var invocations: [Invocation] {
        state.withLock { $0.invocations }
    }

    /// Each element of `stdoutScripts` is consumed by one `run` call, in order;
    /// once exhausted, calls produce no output. `delayNanoseconds` makes every
    /// run call take that long — for tests that care how long a process lived.
    public init(stdoutScripts: [[String]] = [], exitCode: Int32 = 0, delayNanoseconds: UInt64 = 0) {
        state = Mutex(State(stdoutScripts: stdoutScripts, exitCode: exitCode, delayNanoseconds: delayNanoseconds))
    }

    /// Changes the exit code for subsequent run calls (e.g. healthy setup,
    /// then a failing launch).
    public func setExitCode(_ code: Int32) {
        state.withLock { $0.exitCode = code }
    }

    @discardableResult
    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory _: URL?,
        outputLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let (script, code, delay) = state.withLock { state -> ([String], Int32, UInt64) in
            state.invocations.append(Invocation(
                executable: executable.path,
                arguments: arguments,
                environment: environment
            ))
            let script = state.stdoutScripts.isEmpty ? [] : state.stdoutScripts.removeFirst()
            return (script, state.exitCode, state.delayNanoseconds)
        }
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        for line in script {
            outputLine?(line)
        }
        return ProcessResult(exitCode: code)
    }
}

/// Copies a prepared fixture file instead of hitting the network.
public struct FakeDownloader: Downloading {
    public var fixture: URL

    public init(fixture: URL) {
        self.fixture = fixture
    }

    public func download(
        from _: URL,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fixture, to: destination)
        progress?(1.0)
    }
}

/// Pretends a DMG mounts at a prepared fixture directory.
public final class FakeMounter: DiskImageMounting, Sendable {
    private struct State {
        var mountPoint: URL
        var mounted: [URL] = []
        var unmounted: [URL] = []
    }

    private let state: Mutex<State>

    public var mounted: [URL] {
        state.withLock { $0.mounted }
    }

    public var unmounted: [URL] {
        state.withLock { $0.unmounted }
    }

    public init(mountPoint: URL) {
        state = Mutex(State(mountPoint: mountPoint))
    }

    public func mount(dmg: URL) async throws -> URL {
        state.withLock { state in
            state.mounted.append(dmg)
            return state.mountPoint
        }
    }

    public func unmount(_ mountPoint: URL) async {
        state.withLock { $0.unmounted.append(mountPoint) }
    }
}
