import Foundation
import GMModel
import GMSystem
import GMTestSupport
import Synchronization
import Testing
@testable import GMRuntime

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-rt-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a runtime tarball fixture mimicking the Gcenx GPTK layout.
private func makeRuntimeFixture(in dir: URL) async throws -> URL {
    let tree = dir.appendingPathComponent("tree/Game Porting Toolkit.app/Contents/Resources/wine/bin")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho fake wine\n".utf8).write(to: tree.appendingPathComponent("wine64"))
    try Data("#!/bin/sh\necho fake wineserver\n".utf8).write(to: tree.appendingPathComponent("wineserver"))
    let archive = dir.appendingPathComponent("runtime.tar.gz")
    let result = try await SubprocessRunner().run(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-czf", archive.path, "-C", dir.appendingPathComponent("tree").path, "Game Porting Toolkit.app"],
        environment: nil,
        currentDirectory: nil,
        outputLine: nil
    )
    try #require(result.exitCode == 0)
    return archive
}

@Suite("RuntimeManifest")
struct RuntimeManifestTests {
    @Test func bundledManifestDecodes() throws {
        let manifest = try RuntimeManifest.bundled()
        #expect(manifest.defaultRuntimeID == "gptk-3.0-3")
        let entry = try #require(manifest.entries.first { $0.id == "gptk-3.0-3" })
        #expect(entry.url.host() == "github.com")
        #expect(entry.sha256.count == 64)
        #expect(entry.wineBinaryRelativePath.hasSuffix("wine/bin/wine64"))
        #expect(entry.bundledGPTKVersion == "3.0")

        // The newer Wine that Steam's CEF UI needs is a second manifest entry.
        // It carries no GPTK/D3DMetal layers and uses a single `wine` binary
        // (new WoW64), not GPTK's `wine64`.
        let wine = try #require(manifest.entries.first { $0.id == "wine-staging-11.10" })
        #expect(wine.sha256 == "940bdd1a177872020be01c5c33917cb8eecc1cc3193ad554914fb6efd90d7889")
        #expect(wine.wineBinaryRelativePath.hasSuffix("wine/bin/wine"))
        #expect(wine.bundledGPTKVersion == nil)
    }
}

@Suite("RuntimeStore")
struct RuntimeStoreTests {
    @Test func emptyStoreListsNothing() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        #expect(try await store.installedRuntimes().isEmpty)
    }

    @Test func savedDescriptorRoundTrips() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        let descriptor = RuntimeDescriptor(
            id: "gptk-3.0-3",
            displayVersion: "GPTK 3.0-3",
            wineBinaryRelativePath: "Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
            gptk: .installed(version: "3.0")
        )
        try await store.save(descriptor)
        #expect(try await store.installedRuntimes() == [descriptor])
        #expect(try await store.descriptor(id: "gptk-3.0-3") == descriptor)

        let wine = await store.wineBinary(for: descriptor)
        #expect(wine.path.hasSuffix("runtimes/gptk-3.0-3/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"))
    }
}

@Suite("RuntimeInstaller")
struct RuntimeInstallerTests {
    @Test func installsVerifiesUnpacksAndDequarantines() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await makeRuntimeFixture(in: dir)
        let sha = try SHA256.hexDigest(of: fixture)

        let root = dir.appendingPathComponent("approot")
        let store = RuntimeStore(root: root)
        let xattrRunner = FakeRunner()
        let installer = RuntimeInstaller(
            store: store,
            downloader: FakeDownloader(fixture: fixture),
            runner: SubprocessRunner(),
            quarantineRunner: xattrRunner
        )
        let entry = try RuntimeManifest.Entry(
            id: "gptk-test",
            displayVersion: "GPTK test",
            url: #require(URL(string: "https://example.com/runtime.tar.gz")),
            sha256: sha,
            wineBinaryRelativePath: "Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
            bundledGPTKVersion: "3.0"
        )
        let phases = Mutex<[RuntimePhase]>([])
        let descriptor = try await installer.install(entry: entry) { phase, _ in
            phases.withLock {
                if $0.last != phase {
                    $0.append(phase)
                }
            }
        }

        #expect(descriptor.id == "gptk-test")
        #expect(descriptor.gptk == .installed(version: "3.0"))
        let wine = await store.wineBinary(for: descriptor)
        #expect(FileManager.default.fileExists(atPath: wine.path))
        #expect(try await store.descriptor(id: "gptk-test") == descriptor)
        // The runtime tree must be de-quarantined or Gatekeeper blocks exec.
        let xattr = try #require(xattrRunner.invocations.first)
        #expect(xattr.executable == "/usr/bin/xattr")
        #expect(xattr.arguments.contains("com.apple.quarantine"))
        let seen = phases.withLock { $0 }
        #expect(seen == [.downloading, .verifying, .unpacking, .finishing])
    }

    @Test func checksumMismatchAborts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await makeRuntimeFixture(in: dir)

        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        let installer = RuntimeInstaller(
            store: store,
            downloader: FakeDownloader(fixture: fixture),
            runner: SubprocessRunner(),
            quarantineRunner: FakeRunner()
        )
        let entry = try RuntimeManifest.Entry(
            id: "gptk-bad",
            displayVersion: "GPTK bad",
            url: #require(URL(string: "https://example.com/runtime.tar.gz")),
            sha256: String(repeating: "0", count: 64),
            wineBinaryRelativePath: "Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
            bundledGPTKVersion: nil
        )
        await #expect(throws: RuntimeError.self) {
            _ = try await installer.install(entry: entry, progress: nil)
        }
        // Nothing half-installed left behind.
        #expect(try await store.installedRuntimes().isEmpty)
    }

    @Test func missingWineBinaryAfterUnpackFails() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await makeRuntimeFixture(in: dir)
        let sha = try SHA256.hexDigest(of: fixture)

        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        let installer = RuntimeInstaller(
            store: store,
            downloader: FakeDownloader(fixture: fixture),
            runner: SubprocessRunner(),
            quarantineRunner: FakeRunner()
        )
        let entry = try RuntimeManifest.Entry(
            id: "gptk-wrong-layout",
            displayVersion: "GPTK wrong",
            url: #require(URL(string: "https://example.com/runtime.tar.gz")),
            sha256: sha,
            wineBinaryRelativePath: "definitely/not/here/wine64",
            bundledGPTKVersion: nil
        )
        await #expect(throws: RuntimeError.archiveLayoutUnrecognized) {
            _ = try await installer.install(entry: entry, progress: nil)
        }
    }
}
