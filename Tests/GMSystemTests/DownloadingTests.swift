import Foundation
import Synchronization
import Testing
@testable import GMSystem

/// Real URLSessionDownloader round-trips against file:// URLs — the delegate
/// wiring, destination handling, and overwrite behavior all run for real
/// without touching the network.
@Suite("URLSessionDownloader")
struct URLSessionDownloaderTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-download-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func downloadsToDestinationCreatingDirectoriesAndReportsCompletion() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.bin")
        let payload = Data((0 ..< 4096).map { UInt8($0 % 251) })
        try payload.write(to: source)

        let destination = dir.appendingPathComponent("nested/dir/downloaded.bin")
        let finalProgress = Mutex<Double>(0)
        let downloader = URLSessionDownloader(timeout: 30)
        try await downloader.download(from: source, to: destination) { fraction in
            finalProgress.withLock { $0 = max($0, fraction) }
        }

        #expect(try Data(contentsOf: destination) == payload)
        #expect(finalProgress.withLock { $0 } == 1.0)
    }

    @Test func downloadOverwritesExistingDestination() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.bin")
        try Data("fresh".utf8).write(to: source)
        let destination = dir.appendingPathComponent("out.bin")
        try Data("stale leftover from a previous attempt".utf8).write(to: destination)

        try await URLSessionDownloader(timeout: 30).download(from: source, to: destination, progress: nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "fresh")
    }

    @Test func missingSourceThrows() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            try await URLSessionDownloader(timeout: 30).download(
                from: dir.appendingPathComponent("nope.bin"),
                to: dir.appendingPathComponent("out.bin"),
                progress: nil
            )
        }
    }
}
