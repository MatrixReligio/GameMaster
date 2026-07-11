import Foundation

/// Abstraction over mounting disk images (Apple's GPTK ships as a DMG).
public protocol DiskImageMounting: Sendable {
    /// Mounts the image and returns the mount point.
    func mount(dmg: URL) async throws -> URL
    func unmount(_ mountPoint: URL) async
}

public enum DiskImageError: Error, LocalizedError, Equatable {
    case attachFailed(exitCode: Int32)
    case noMountPoint

    public var errorDescription: String? {
        switch self {
        case let .attachFailed(code):
            String(localized: "Could not open the disk image (hdiutil exit \(code)).")
        case .noMountPoint:
            String(localized: "The disk image did not produce a mountable volume.")
        }
    }
}

/// Real mounter backed by `hdiutil attach/detach`.
public struct HdiutilMounter: DiskImageMounting {
    private let runner: any ProcessRunning
    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    public func mount(dmg: URL) async throws -> URL {
        let output = OutputCollector()
        let result = try await runner.run(
            executable: Self.hdiutil,
            arguments: ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"],
            environment: nil,
            currentDirectory: nil
        ) { line in
            output.append(line)
        }
        guard result.exitCode == 0 else {
            throw DiskImageError.attachFailed(exitCode: result.exitCode)
        }
        let plistData = Data(output.joined().utf8)
        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
            let dict = plist as? [String: Any],
            let entities = dict["system-entities"] as? [[String: Any]],
            let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw DiskImageError.noMountPoint
        }
        return URL(fileURLWithPath: mountPoint)
    }

    public func unmount(_ mountPoint: URL) async {
        _ = try? await runner.run(
            executable: Self.hdiutil,
            arguments: ["detach", mountPoint.path, "-quiet"],
            environment: nil,
            currentDirectory: nil,
            outputLine: nil
        )
    }
}

/// Thread-safe line accumulator (ProcessRunning may call back on any thread).
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
