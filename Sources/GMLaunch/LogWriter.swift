import Foundation
import Synchronization

/// Appends output lines to a log file. Creates the file on first line so
/// silent launches still produce a (small) trace of the invocation.
public final class LogWriter: Sendable {
    private let state: Mutex<FileHandle?>
    public let file: URL

    public init(file: URL) {
        self.file = file
        FileManager.default.createFile(atPath: file.path, contents: nil)
        state = Mutex(try? FileHandle(forWritingTo: file))
    }

    public func append(_ line: String) {
        state.withLock { handle in
            try? handle?.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    deinit {
        state.withLock { try? $0?.close() }
    }
}
