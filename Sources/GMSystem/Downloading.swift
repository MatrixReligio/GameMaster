import Foundation

/// Abstraction over file downloads with progress reporting.
public protocol Downloading: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws
}

public enum DownloadError: Error, LocalizedError, Equatable {
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case let .badStatus(code):
            String(localized: "Download failed with HTTP status \(code).")
        }
    }
}

/// Real downloader backed by a URLSession download task. A download task streams
/// straight to a temp file with OS-managed buffering — unlike byte-by-byte
/// `URLSession.bytes` iteration, which is pathologically slow for large files
/// (hundreds of MB) and can exhaust the request timeout.
public struct URLSessionDownloader: Downloading {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 1800) {
        self.timeout = timeout
    }

    public func download(
        from url: URL,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let config = URLSessionConfiguration.default
        // Large runtime downloads must not die on the default 60s request
        // timeout; cap the whole resource instead.
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = true
        let delegate = DownloadProgressDelegate(progress: progress)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw DownloadError.badStatus(http.statusCode)
        }

        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        // The temp file and destination may be on different volumes; moveItem
        // handles the cross-volume copy, falling back to copy+remove.
        try fm.moveItem(at: tempURL, to: destination)
        progress?(1.0)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    /// Required by URLSessionDownloadDelegate; the async download(from:) API
    /// returns the temp URL itself, so this is a no-op.
    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo _: URL
    ) {}

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
