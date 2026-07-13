import Foundation
import Testing
@testable import GMLaunch

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-probe-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// wineserver liveness detection: the server directory for a prefix is
/// derived from the prefix directory's device/inode, and liveness is the
/// POSIX write lock wineserver holds on its `lock` file — NOT the directory's
/// existence (stale dirs survive every exit).
@Suite("WineServerProbe")
struct WineServerProbeTests {
    @Test func inactiveWhenServerDirectoryMissing() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let probe = WineServerProbe(serverRoots: [root.appendingPathComponent("wine-root")])
        #expect(!probe.isActive(prefix: prefix))
    }

    /// A leftover server dir with an UNLOCKED lock file is a previous session's
    /// corpse — it must read as inactive, or every bottle would look busy
    /// forever after its first launch.
    @Test func staleUnlockedServerDirectoryIsInactive() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let serverRoot = root.appendingPathComponent("wine-root")
        let serverDir = try #require(WineServerProbe.serverDirectoryName(forPrefix: prefix))
        let dir = serverRoot.appendingPathComponent(serverDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("lock"))

        let probe = WineServerProbe(serverRoots: [serverRoot])
        #expect(!probe.isActive(prefix: prefix))
    }

    /// Live path: another process holds an exclusive lock on the lock file
    /// (what a running wineserver does) → active; lock released → inactive.
    @Test func detectsLiveLockHolder() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)

        let serverRoot = root.appendingPathComponent("wine-root")
        let serverDir = try #require(WineServerProbe.serverDirectoryName(forPrefix: prefix))
        let dir = serverRoot.appendingPathComponent(serverDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appendingPathComponent("lock")
        try Data().write(to: lock)

        // A child process takes the exclusive lock, prints, and sleeps —
        // standing in for a live wineserver.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", """
        import fcntl, sys, time
        f = open(sys.argv[1], "w")
        fcntl.lockf(f, fcntl.LOCK_EX)
        print("locked", flush=True)
        time.sleep(60)
        """, lock.path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { holder.terminate() }
        // Wait for the child to confirm it holds the lock.
        let line = out.fileHandleForReading.availableData
        #expect(String(data: line, encoding: .utf8)?.contains("locked") == true)

        let probe = WineServerProbe(serverRoots: [serverRoot])
        #expect(probe.isActive(prefix: prefix))

        holder.terminate()
        holder.waitUntilExit()
        #expect(!probe.isActive(prefix: prefix))
    }
}
