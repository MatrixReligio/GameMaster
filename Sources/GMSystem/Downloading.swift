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

/// Real downloader backed by URLSession with byte-level progress.
public struct URLSessionDownloader: Downloading {
    public init() {}

    public func download(
        from url: URL,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw DownloadError.badStatus(http.statusCode)
        }
        let expected = response.expectedContentLength

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data(capacity: 1 << 16)
        var written: Int64 = 0
        var lastReported = -1.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 16 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    let fraction = Double(written) / Double(expected)
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress?(fraction)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        progress?(1.0)
    }
}
