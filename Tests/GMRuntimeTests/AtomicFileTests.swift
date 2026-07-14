import Foundation
import Testing
@testable import GMRuntime

@Suite("AtomicFile")
struct AtomicFileTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-atomicfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func createsTargetWhenAbsent() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("src.bin")
        try Data("hello".utf8).write(to: source)
        let target = dir.appendingPathComponent("sub/target.bin")

        try AtomicFile.replace(at: target, withCopyOf: source)

        #expect(try String(contentsOf: target, encoding: .utf8) == "hello")
        #expect(residue(in: target.deletingLastPathComponent()).isEmpty)
    }

    @Test func overwritesExistingTarget() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.bin")
        try Data("old".utf8).write(to: target)
        let source = dir.appendingPathComponent("src.bin")
        try Data("new-and-longer".utf8).write(to: source)

        try AtomicFile.replace(at: target, withCopyOf: source)

        #expect(try String(contentsOf: target, encoding: .utf8) == "new-and-longer")
        #expect(residue(in: dir).isEmpty)
    }

    /// The whole point: many placers writing the SAME source content at one
    /// target concurrently must all succeed, land the full content, and leave
    /// no temp behind — no removeItem→copyItem window, no EEXIST loser.
    @Test func concurrentReplacesAllSucceedWithNoResidue() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = String(repeating: "Z", count: 64 * 1024)
        let source = dir.appendingPathComponent("src.bin")
        try Data(payload.utf8).write(to: source)
        let target = dir.appendingPathComponent("target.bin")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 64 {
                group.addTask { try AtomicFile.replace(at: target, withCopyOf: source) }
            }
            try await group.waitForAll()
        }

        #expect(try String(contentsOf: target, encoding: .utf8) == payload)
        #expect(residue(in: dir).isEmpty)
    }

    private func residue(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains(".gm-") } ?? []
    }
}
