import CryptoKit
import Foundation

public enum SHA256 {
    /// Streaming SHA-256 of a file (runtime tarballs are hundreds of MB —
    /// never load them whole).
    public static func hexDigest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
