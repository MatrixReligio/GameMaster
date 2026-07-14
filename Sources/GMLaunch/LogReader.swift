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
        // Lossy on purpose: a tail can start mid-UTF-8-character, and the
        // failable String(bytes:encoding:) would drop the whole tail there.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: tailData(of: url, maxBytes: maxBytes), as: UTF8.self)
    }

    /// The last up-to-`maxBytes` bytes of `url` (empty if it can't be opened or
    /// `maxBytes <= 0`). Strictly capped: `read(upToCount:)` never returns more
    /// than `maxBytes`, even if the file keeps growing between the moment we
    /// measure its size and the moment we read — so a still-writing log can't
    /// push the result past the cap.
    static func tailData(of url: URL, maxBytes: Int) -> Data {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let cap = UInt64(maxBytes)
        let start = size > cap ? size - cap : 0
        try? handle.seek(toOffset: start)
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }
}
