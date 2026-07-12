import Foundation
import GMTestSupport
import Synchronization
import Testing
@testable import GMSystem

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SubprocessRunner")
struct SubprocessRunnerTests {
    @Test func capturesMergedOutputAndExitCode() async throws {
        let runner = SubprocessRunner()
        let collected = Mutex<[String]>([])
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out1; echo err1 1>&2; exit 3"],
            environment: nil,
            currentDirectory: nil
        ) { line in
            collected.withLock { $0.append(line) }
        }
        #expect(result.exitCode == 3)
        let lines = collected.withLock { $0 }
        #expect(lines.contains("out1"))
        #expect(lines.contains("err1"))
    }

    /// A launcher-style helper exits immediately while its child keeps the
    /// inherited stdio open (`wine start /unix` spawning Steam). With no
    /// outputLine there is no pipe, so run() must return when the HELPER
    /// exits — not block until the child's tree closes the pipe. This hung
    /// fresh Steam installs at "Configuring…" for the client's whole lifetime.
    @Test func returnsOnHelperExitWhenNoOutputRequested() async throws {
        let runner = SubprocessRunner()
        let started = Date()
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & exit 0"],
            environment: nil,
            currentDirectory: nil,
            outputLine: nil
        )
        #expect(result.exitCode == 0)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func mergesProvidedEnvironmentOverInherited() async throws {
        let runner = SubprocessRunner()
        let collected = Mutex<[String]>([])
        _ = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [],
            environment: ["GM_TEST_VAR": "hello42"],
            currentDirectory: nil
        ) { line in
            collected.withLock { $0.append(line) }
        }
        let lines = collected.withLock { $0 }
        #expect(lines.contains("GM_TEST_VAR=hello42"))
        // PATH must survive the merge — wine cannot run in an empty environment.
        #expect(lines.contains { $0.hasPrefix("PATH=") })
    }

    @Test func honorsCurrentDirectory() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SubprocessRunner()
        let collected = Mutex<[String]>([])
        _ = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            arguments: [],
            environment: nil,
            currentDirectory: dir
        ) { line in
            collected.withLock { $0.append(line) }
        }
        let lines = collected.withLock { $0 }
        #expect(lines.first?.hasSuffix(dir.lastPathComponent) == true)
    }
}

@Suite("SHA256")
struct SHA256Tests {
    @Test func knownVectors() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let empty = dir.appendingPathComponent("empty")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        #expect(try SHA256.hexDigest(of: empty)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let abc = dir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        #expect(try SHA256.hexDigest(of: abc)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite("Archive")
struct ArchiveTests {
    @Test func extractsTarball() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a source tree and tar it with the system tar.
        let src = dir.appendingPathComponent("src/payload")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: src.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(
            at: src.appendingPathComponent("link"),
            withDestinationURL: URL(fileURLWithPath: "file.txt")
        )
        let archive = dir.appendingPathComponent("payload.tar.gz")
        let runner = SubprocessRunner()
        let tarResult = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", archive.path, "-C", dir.appendingPathComponent("src").path, "payload"],
            environment: nil,
            currentDirectory: nil,
            outputLine: nil
        )
        #expect(tarResult.exitCode == 0)

        let dest = dir.appendingPathComponent("out")
        try await Archive.extractTar(archive, into: dest, runner: runner)
        let extracted = dest.appendingPathComponent("payload/file.txt")
        #expect(try String(contentsOf: extracted, encoding: .utf8) == "hello")
        // Symlinks must survive extraction (D3DMetal's unix .so files are symlinks).
        let linkPath = dest.appendingPathComponent("payload/link").path
        let attrs = try FileManager.default.attributesOfItem(atPath: linkPath)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func failingExtractionThrows() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogus = dir.appendingPathComponent("bogus.tar.xz")
        try Data("not a tarball".utf8).write(to: bogus)
        await #expect(throws: (any Error).self) {
            try await Archive.extractTar(bogus, into: dir.appendingPathComponent("out"), runner: SubprocessRunner())
        }
    }
}

@Suite("HdiutilMounter")
struct HdiutilMounterTests {
    @Test func mountParsesPlistAndUsesExpectedArguments() async throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>content-hint</key>
                    <string>GUID_partition_scheme</string>
                </dict>
                <dict>
                    <key>mount-point</key>
                    <string>/Volumes/Evaluation environment for Windows games 3.0</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let runner = FakeRunner(stdoutScripts: [plist.components(separatedBy: "\n")])
        let mounter = HdiutilMounter(runner: runner)
        let mountPoint = try await mounter.mount(dmg: URL(fileURLWithPath: "/tmp/test.dmg"))
        #expect(mountPoint.path == "/Volumes/Evaluation environment for Windows games 3.0")

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable == "/usr/bin/hdiutil")
        #expect(invocation.arguments == ["attach", "/tmp/test.dmg", "-nobrowse", "-readonly", "-plist"])
    }

    @Test func mountFailureThrows() async throws {
        let runner = FakeRunner(stdoutScripts: [], exitCode: 1)
        let mounter = HdiutilMounter(runner: runner)
        await #expect(throws: (any Error).self) {
            _ = try await mounter.mount(dmg: URL(fileURLWithPath: "/tmp/nope.dmg"))
        }
    }

    @Test func unmountDetaches() async throws {
        let runner = FakeRunner()
        let mounter = HdiutilMounter(runner: runner)
        await mounter.unmount(URL(fileURLWithPath: "/Volumes/Test"))
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable == "/usr/bin/hdiutil")
        #expect(invocation.arguments == ["detach", "/Volumes/Test", "-quiet"])
    }
}

@Suite("Quarantine")
struct QuarantineTests {
    @Test func removesRecursively() async throws {
        let runner = FakeRunner()
        try await Quarantine.remove(from: URL(fileURLWithPath: "/tmp/runtime"), runner: runner)
        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executable == "/usr/bin/xattr")
        #expect(invocation.arguments == ["-dr", "com.apple.quarantine", "/tmp/runtime"])
    }
}
