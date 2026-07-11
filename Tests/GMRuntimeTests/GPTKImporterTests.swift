import Foundation
import GMModel
import GMSystem
import GMTestSupport
import Testing
@testable import GMRuntime

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-gptk-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Lays out a fake mounted "Evaluation environment for Windows games" volume.
private func makeEvalVolume(in dir: URL, name: String = "Evaluation environment for Windows games 3.0") throws -> URL {
    let volume = dir.appendingPathComponent(name, isDirectory: true)
    let external = volume.appendingPathComponent("redist/lib/external", isDirectory: true)
    let unixDir = volume.appendingPathComponent("redist/lib/wine/x86_64-unix", isDirectory: true)
    let winDir = volume.appendingPathComponent("redist/lib/wine/x86_64-windows", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
    try Data("dylib".utf8).write(to: external.appendingPathComponent("libd3dshared.dylib"))
    let framework = external.appendingPathComponent("D3DMetal.framework/Versions/A", isDirectory: true)
    try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
    try Data("d3dmetal".utf8).write(to: framework.appendingPathComponent("D3DMetal"))
    // Apple ships the unix .so entries as symlinks into external/.
    try FileManager.default.createSymbolicLink(
        at: unixDir.appendingPathComponent("d3d11.so"),
        withDestinationURL: URL(fileURLWithPath: "../../external/libd3dshared.dylib")
    )
    try Data("dll".utf8).write(to: winDir.appendingPathComponent("d3d11.dll"))
    return volume
}

/// Installs a fake runtime into the store so the importer has a target.
private func installFakeRuntime(store: RuntimeStore, id: String) async throws -> RuntimeDescriptor {
    let wineRoot = "Game Porting Toolkit.app/Contents/Resources/wine"
    let dir = await store.runtimeDirectory(id: id)
    let bin = dir.appendingPathComponent("\(wineRoot)/bin", isDirectory: true)
    let lib = dir.appendingPathComponent("\(wineRoot)/lib", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: lib.appendingPathComponent("external", isDirectory: true),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: lib.appendingPathComponent("wine", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("old-dylib".utf8).write(
        to: lib.appendingPathComponent("external/libd3dshared.dylib")
    )
    // A core wine builtin that MUST survive a D3DMetal refresh — the eval
    // environment ships only DirectX shims, so a wholesale replace would
    // brick the runtime.
    try FileManager.default.createDirectory(
        at: lib.appendingPathComponent("wine/x86_64-unix", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("core-builtin".utf8).write(
        to: lib.appendingPathComponent("wine/x86_64-unix/ntdll.so")
    )
    try Data("wine".utf8).write(to: bin.appendingPathComponent("wine64"))
    let descriptor = RuntimeDescriptor(
        id: id,
        displayVersion: "GPTK test",
        wineBinaryRelativePath: "\(wineRoot)/bin/wine64",
        gptk: .installed(version: "3.0-bundled")
    )
    try await store.save(descriptor)
    return descriptor
}

@Suite("GPTKImporter")
struct GPTKImporterTests {
    @Test func importMergesD3DMetalWithoutBrickingCoreBuiltins() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let volume = try makeEvalVolume(in: dir)
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")

        let mounter = FakeMounter(mountPoint: volume)
        let importer = GPTKImporter(store: store, mounter: mounter, runner: SubprocessRunner())
        let descriptor = try await importer.importGPTK(
            dmg: URL(fileURLWithPath: "/tmp/Evaluation_environment_for_Windows_games_3.0.dmg"),
            into: "rt"
        )

        #expect(descriptor.gptk == .installed(version: "3.0"))
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        // New D3DMetal libraries overlaid…
        #expect(try String(
            contentsOf: lib.appendingPathComponent("external/libd3dshared.dylib"),
            encoding: .utf8
        ) == "dylib")
        #expect(FileManager.default.fileExists(
            atPath: lib.appendingPathComponent("external/D3DMetal.framework/Versions/A/D3DMetal").path
        ))
        // …DirectX shim symlinks present as symlinks…
        let soAttrs = try FileManager.default.attributesOfItem(
            atPath: lib.appendingPathComponent("wine/x86_64-unix/d3d11.so").path
        )
        #expect(soAttrs[.type] as? FileAttributeType == .typeSymbolicLink)
        // …AND the pre-existing core builtin survives (merge, not replace).
        #expect(try String(
            contentsOf: lib.appendingPathComponent("wine/x86_64-unix/ntdll.so"),
            encoding: .utf8
        ) == "core-builtin")
        // …descriptor persisted and volume unmounted.
        let saved = try await store.descriptor(id: "rt")
        #expect(saved?.gptk == .installed(version: "3.0"))
        #expect(mounter.unmounted.count == 1)
    }

    @Test func rejectsForeignDMGAndStillUnmounts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bogusVolume = dir.appendingPathComponent("Some Other Tool", isDirectory: true)
        try FileManager.default.createDirectory(at: bogusVolume, withIntermediateDirectories: true)
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")

        let mounter = FakeMounter(mountPoint: bogusVolume)
        let importer = GPTKImporter(store: store, mounter: mounter, runner: SubprocessRunner())
        await #expect(throws: RuntimeError.dmgLayoutUnrecognized) {
            _ = try await importer.importGPTK(dmg: URL(fileURLWithPath: "/tmp/other.dmg"), into: "rt")
        }
        #expect(mounter.unmounted.count == 1)
        // Runtime untouched.
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        #expect(try String(
            contentsOf: lib.appendingPathComponent("external/libd3dshared.dylib"),
            encoding: .utf8
        ) == "old-dylib")
    }

    @Test func importsDirectlyFromMountedVolume() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let volume = try makeEvalVolume(in: dir)
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        _ = try await installFakeRuntime(store: store, id: "rt")

        let importer = GPTKImporter(
            store: store,
            mounter: FakeMounter(mountPoint: volume),
            runner: SubprocessRunner()
        )
        let descriptor = try await importer.importGPTK(mountedVolume: volume, into: "rt")
        #expect(descriptor.gptk == .installed(version: "3.0"))
    }
}

@Suite("GPTKDetector")
struct GPTKDetectorTests {
    @Test func findsEvalEnvironmentDMGsByName() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = dir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data().write(to: downloads.appendingPathComponent("Evaluation_environment_for_Windows_games_3.0.dmg"))
        try Data().write(to: downloads.appendingPathComponent("Evaluation environment for Windows games 2.1.dmg"))
        try Data().write(to: downloads.appendingPathComponent("SomeInstaller.dmg"))
        try Data().write(to: downloads.appendingPathComponent("notes.txt"))

        let detector = GPTKDetector(searchDirectories: [downloads], volumesDirectory: dir)
        let found = detector.candidateDMGs().map(\.lastPathComponent).sorted()
        #expect(found == [
            "Evaluation environment for Windows games 2.1.dmg",
            "Evaluation_environment_for_Windows_games_3.0.dmg"
        ])
    }

    @Test func findsMountedEvalVolumes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let volumes = dir.appendingPathComponent("Volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
        _ = try makeEvalVolume(in: volumes)
        try FileManager.default.createDirectory(
            at: volumes.appendingPathComponent("Macintosh HD"),
            withIntermediateDirectories: true
        )

        let detector = GPTKDetector(searchDirectories: [], volumesDirectory: volumes)
        let found = detector.candidateMountedVolumes().map(\.lastPathComponent)
        #expect(found == ["Evaluation environment for Windows games 3.0"])
    }
}

@Suite("MetalFXEnabler")
struct MetalFXEnablerTests {
    @Test func preparesNvngxFilesPerAppleReadme() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuntimeStore(root: dir.appendingPathComponent("approot"))
        let descriptor = try await installFakeRuntime(store: store, id: "rt")
        let lib = await store.runtimeDirectory(id: "rt")
            .appendingPathComponent("Game Porting Toolkit.app/Contents/Resources/wine/lib")
        let unixDir = lib.appendingPathComponent("wine/x86_64-unix")
        let winDir = lib.appendingPathComponent("wine/x86_64-windows")
        try FileManager.default.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        try Data("so".utf8).write(to: unixDir.appendingPathComponent("nvngx-on-metalfx.so"))
        try Data("dll".utf8).write(to: winDir.appendingPathComponent("nvngx-on-metalfx.dll"))
        try Data("nvapi".utf8).write(to: winDir.appendingPathComponent("nvapi64.dll"))

        let prefix = dir.appendingPathComponent("prefix")
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)

        let enabler = MetalFXEnabler(store: store)
        try await enabler.prepare(runtimeID: "rt", prefix: prefix)

        // Renamed per Apple's Read Me…
        #expect(FileManager.default.fileExists(atPath: unixDir.appendingPathComponent("nvngx.so").path))
        #expect(FileManager.default.fileExists(atPath: winDir.appendingPathComponent("nvngx.dll").path))
        // …and both dlls copied into the prefix's system32.
        #expect(try String(
            contentsOf: system32.appendingPathComponent("nvngx.dll"), encoding: .utf8
        ) == "dll")
        #expect(try String(
            contentsOf: system32.appendingPathComponent("nvapi64.dll"), encoding: .utf8
        ) == "nvapi")

        // Idempotent: preparing again must not fail.
        try await enabler.prepare(runtimeID: "rt", prefix: prefix)
    }
}
