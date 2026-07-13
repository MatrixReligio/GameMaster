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

        // The Steam run runtime for D3D11 games: a Sikarugir Wine 10 engine
        // (exports macdrv_functions, which DXMT needs for its Metal layer —
        // vanilla Gcenx builds strip it) with DXMT preinstalled as builtins.
        let sika = try #require(manifest.entries.first { $0.id == "sikarugir-10.0-6-dxmt-0.80" })
        #expect(sika.sha256.count == 64)
        #expect(sika.url.host() == "github.com")
        // runtime-assets-2 is the re-assembled bundle that carries the
        // license texts and THIRD-PARTY-NOTICES for its LGPL/open-source
        // binaries; earlier assets shipped none.
        #expect(sika.url.path().contains("runtime-assets-2"))
        #expect(sika.wineBinaryRelativePath == "wswine.bundle/bin/wine")
        #expect(sika.bundledGPTKVersion == nil)
        #expect(sika.bundledDXMTVersion == "0.80")
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

    /// A corrupt runtime.json must be reported, not silently filtered —
    /// silence made an installed runtime "disappear" and triggered a
    /// pointless re-download. The file stays on disk for recovery.
    @Test func listingReportsCorruptEntriesWithoutDeleting() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        let descriptor = RuntimeDescriptor(
            id: "gptk-3.0-3",
            displayVersion: "GPTK 3.0-3",
            wineBinaryRelativePath: "wine/bin/wine64",
            gptk: .installed(version: "3.0")
        )
        try await store.save(descriptor)
        let corruptDir = root.appendingPathComponent("runtimes/broken", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptFile = corruptDir.appendingPathComponent("runtime.json")
        try Data("not json".utf8).write(to: corruptFile)

        let listing = try await store.listing()
        #expect(listing.runtimes == [descriptor])
        // /var vs /private/var: compare symlink-resolved paths.
        #expect(
            listing.corruptFiles.map { $0.resolvingSymlinksInPath().path }
                == [corruptFile.resolvingSymlinksInPath().path]
        )
        #expect(FileManager.default.fileExists(atPath: corruptFile.path))
        // installedRuntimes still returns the healthy entries.
        #expect(try await store.installedRuntimes() == [descriptor])
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

    /// A crash right after the payload swap must not leave a runtime dir
    /// with no runtime.json — that reads as "missing" and pointlessly
    /// re-downloads. The metadata must land ATOMICALLY with the payload,
    /// so the runtime is complete even if the process dies immediately after.
    @Test func installLandsMetadataAtomicallyWithPayload() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await makeRuntimeFixture(in: dir)
        let sha = try SHA256.hexDigest(of: fixture)
        let root = dir.appendingPathComponent("approot")
        let store = RuntimeStore(root: root)
        let installer = RuntimeInstaller(
            store: store,
            downloader: FakeDownloader(fixture: fixture),
            runner: SubprocessRunner(),
            quarantineRunner: FakeRunner()
        )
        let entry = try RuntimeManifest.Entry(
            id: "gptk-test",
            displayVersion: "GPTK test",
            url: #require(URL(string: "https://example.com/runtime.tar.gz")),
            sha256: sha,
            wineBinaryRelativePath: "Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
            bundledGPTKVersion: "3.0"
        )

        struct Crash: Error {}
        await #expect(throws: Crash.self) {
            _ = try await installer.install(entry: entry, progress: nil) { throw Crash() }
        }

        // Despite the crash right after the swap, the runtime is COMPLETE:
        // payload present AND discoverable via its metadata.
        let rtDir = await store.runtimeDirectory(id: "gptk-test")
        #expect(FileManager.default.fileExists(
            atPath: rtDir.appendingPathComponent(entry.wineBinaryRelativePath).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: rtDir.appendingPathComponent(RuntimeStore.metadataFileName).path
        ))
        #expect(try await store.descriptor(id: "gptk-test") != nil)
    }

    @Test func manifestDXMTVersionLandsInDescriptor() async throws {
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
            id: "sika-test",
            displayVersion: "Sikarugir test",
            url: #require(URL(string: "https://example.com/runtime.tar.gz")),
            sha256: sha,
            wineBinaryRelativePath: "Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
            bundledGPTKVersion: nil,
            bundledDXMTVersion: "0.80"
        )
        let descriptor = try await installer.install(entry: entry, progress: nil)
        #expect(descriptor.dxmt == .installed(version: "0.80"))
        #expect(descriptor.gptk == .none)
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
