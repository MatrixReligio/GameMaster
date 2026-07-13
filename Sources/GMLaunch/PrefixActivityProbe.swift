import Foundation

/// Whether a bottle's wine prefix has a LIVE wineserver — i.e. Windows
/// programs are still running in it. Games deliberately survive GameMaster
/// quitting, so on relaunch the app must rediscover running bottles instead
/// of showing them as idle (and letting the user delete them mid-game).
public protocol PrefixActivityProbing: Sendable {
    func isActive(prefix: URL) -> Bool
}

/// Real probe. wineserver keeps a per-prefix server directory at
/// `<root>/.wine-<uid>/server-<device hex>-<inode hex>` (device/inode of the
/// prefix directory) and holds a POSIX write lock on the `lock` file inside
/// it for its whole lifetime. Directory existence is NOT liveness — stale
/// dirs survive every exit — but an fcntl lock dies with its process, so
/// querying the lock is an exact, race-free liveness signal.
public struct WineServerProbe: PrefixActivityProbing {
    private let serverRoots: [URL]

    public init(serverRoots: [URL]? = nil) {
        self.serverRoots = serverRoots ?? Self.defaultServerRoots()
    }

    /// Wine derives the server-dir base from TMPDIR when set and /tmp
    /// otherwise; builds differ, so check both (verified: the bundled
    /// runtimes use /tmp/.wine-<uid>/).
    static func defaultServerRoots() -> [URL] {
        var bases = [URL(fileURLWithPath: "/tmp")]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            bases.append(URL(fileURLWithPath: tmp))
        }
        return bases.map { $0.appendingPathComponent(".wine-\(getuid())", isDirectory: true) }
    }

    public func isActive(prefix: URL) -> Bool {
        guard let name = Self.serverDirectoryName(forPrefix: prefix) else { return false }
        return serverRoots.contains { root in
            Self.isLockHeld(root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("lock"))
        }
    }

    /// `server-<dev hex>-<inode hex>` for the prefix directory, exactly as
    /// wine's init_server_dir formats it. nil when the prefix doesn't exist.
    static func serverDirectoryName(forPrefix prefix: URL) -> String? {
        var status = stat()
        guard stat(prefix.path, &status) == 0 else { return nil }
        let dev = UInt64(UInt32(bitPattern: status.st_dev))
        let ino = UInt64(status.st_ino)
        return String(format: "server-%llx-%llx", dev, ino)
    }

    /// True when any process holds a lock on the file (F_GETLK query for a
    /// hypothetical write lock reports the conflicting holder).
    static func isLockHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var probe = flock()
        probe.l_type = Int16(F_WRLCK)
        probe.l_whence = Int16(SEEK_SET)
        probe.l_start = 0
        probe.l_len = 0
        guard fcntl(fd, F_GETLK, &probe) == 0 else { return false }
        return probe.l_type != Int16(F_UNLCK)
    }
}
