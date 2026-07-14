import Foundation

/// Reads a launch log for display. Reads only the tail so a long-running,
/// high-output program (a big log) can't stall the viewer or spike memory, and
/// is safe to call off the main thread (it does blocking file I/O).
public enum LogReader {
    /// Show at most the last 2 MB — plenty of recent context; anything larger
    /// is where synchronous whole-file reads started to hurt.
    public static let defaultMaxBytes = 2 * 1024 * 1024

    /// The tail of `url` (up to `maxBytes`), decoded as UTF-8. Returns "" if the
    /// file can't be opened. A file at or under `maxBytes` is returned whole.
    public static func tail(of url: URL, maxBytes: Int = defaultMaxBytes) -> String {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let cap = UInt64(maxBytes)
        let start = size > cap ? size - cap : 0
        // Always seek — seekToEnd() left the handle at the end, so even start 0
        // must rewind or readToEnd would return nothing.
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        // Lossy on purpose: a tail can start mid-UTF-8-character, and the
        // failable String(bytes:encoding:) would drop the whole tail there.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
