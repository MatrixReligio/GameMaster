import Foundation
import GMLaunch
import Testing
@testable import GMApps

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-fixup-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SteamWebHelperWrapper")
struct SteamWebHelperWrapperTests {
    private func spec() -> InstallerCatalog.WebHelperWrapper {
        InstallerCatalog.WebHelperWrapper(
            cefWindowsDirectory: "C:\\Program Files (x86)\\Steam\\bin\\cef\\cef.win64",
            helperFileName: "steamwebhelper.exe",
            realHelperFileName: "steamwebhelper_real.exe",
            wrapperResourceName: "steamwebhelper_wrapper"
        )
    }

    private struct Fixture {
        let prefix: URL
        let cef: URL
        let wrapper: URL
        var helper: URL {
            cef.appendingPathComponent("steamwebhelper.exe")
        }

        var real: URL {
            cef.appendingPathComponent("steamwebhelper_real.exe")
        }
    }

    /// A prefix with the CEF directory created, plus a small wrapper fixture.
    private func fixture() throws -> Fixture {
        let prefix = try tempDir()
        let cef = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        let wrapper = prefix.appendingPathComponent("wrapper.exe")
        try Data("wrapper-bytes".utf8).write(to: wrapper)
        return Fixture(prefix: prefix, cef: cef, wrapper: wrapper)
    }

    private let wrapperBytes = Data("wrapper-bytes".utf8)

    @Test func backsUpGenuineHelperThenInstallsWrapper() throws {
        let fx = try fixture()
        defer { try? FileManager.default.removeItem(at: fx.prefix) }
        try Data(count: 2_000_000).write(to: fx.helper) // genuine helper is multi-MB

        try SteamWebHelperWrapper.install(spec: spec(), prefix: fx.prefix, wrapperResource: fx.wrapper)

        #expect(try Data(contentsOf: fx.real).count == 2_000_000)
        #expect(try Data(contentsOf: fx.helper) == wrapperBytes)
    }

    @Test func noopWhenSteamNotBootstrapped() throws {
        let fx = try fixture()
        defer { try? FileManager.default.removeItem(at: fx.prefix) }

        try SteamWebHelperWrapper.install(spec: spec(), prefix: fx.prefix, wrapperResource: fx.wrapper)

        #expect(!FileManager.default.fileExists(atPath: fx.helper.path))
        #expect(!FileManager.default.fileExists(atPath: fx.real.path))
    }

    @Test func repairsAfterSteamUpdateOverwroteWrapper() throws {
        let fx = try fixture()
        defer { try? FileManager.default.removeItem(at: fx.prefix) }
        try Data(count: 2_000_000).write(to: fx.helper)
        try SteamWebHelperWrapper.install(spec: spec(), prefix: fx.prefix, wrapperResource: fx.wrapper)

        // Steam self-update drops a fresh genuine helper over our wrapper.
        try FileManager.default.removeItem(at: fx.helper)
        try Data(count: 3_000_000).write(to: fx.helper)
        try SteamWebHelperWrapper.install(spec: spec(), prefix: fx.prefix, wrapperResource: fx.wrapper)

        #expect(try Data(contentsOf: fx.real).count == 3_000_000) // re-captured the new genuine
        #expect(try Data(contentsOf: fx.helper) == wrapperBytes)
    }

    @Test func idempotentWhenAlreadyWrapped() throws {
        let fx = try fixture()
        defer { try? FileManager.default.removeItem(at: fx.prefix) }
        try Data(count: 2_000_000).write(to: fx.helper)
        try SteamWebHelperWrapper.install(spec: spec(), prefix: fx.prefix, wrapperResource: fx.wrapper)
        try SteamWebHelperWrapper.install(spec: spec(), prefix: fx.prefix, wrapperResource: fx.wrapper)

        #expect(try Data(contentsOf: fx.real).count == 2_000_000) // backup not clobbered by the wrapper
        #expect(try Data(contentsOf: fx.helper) == wrapperBytes)
    }

    @Test func throwsWhenWrapperResourceMissing() throws {
        let fx = try fixture()
        defer { try? FileManager.default.removeItem(at: fx.prefix) }
        try Data(count: 2_000_000).write(to: fx.helper)
        let missing = fx.prefix.appendingPathComponent("nope.exe")

        #expect(throws: SteamWebHelperWrapper.WrapperError.wrapperResourceMissing(name: "steamwebhelper_wrapper")) {
            try SteamWebHelperWrapper.install(spec: spec(), prefix: fx.prefix, wrapperResource: missing)
        }
    }

    @Test func bundledWrapperResourceIsPackaged() {
        // The prebuilt PE must ship in the app bundle, or the black-UI fix silently
        // no-ops in production.
        #expect(SteamWebHelperWrapper.bundledResource(named: "steamwebhelper_wrapper") != nil)
    }
}

@Suite("SteamServiceStub")
struct SteamServiceStubTests {
    private func spec() -> InstallerCatalog.ServiceStub {
        InstallerCatalog.ServiceStub(
            windowsPaths: [
                "C:\\Program Files (x86)\\Steam\\bin\\SteamService.exe",
                "C:\\Program Files (x86)\\Common Files\\Steam\\steamservice.exe"
            ],
            stubResourceName: "steamservice_stub"
        )
    }

    private struct Fixture {
        let prefix: URL
        let stub: URL
        let targets: [URL]
    }

    /// Writes a stub fixture plus a genuine service exe at each target path.
    private func fixture(genuineSizes: [Int]) throws -> Fixture {
        let prefix = try tempDir()
        let stub = prefix.appendingPathComponent("stub.exe")
        try Data(count: 4096).write(to: stub)
        var targets: [URL] = []
        for (path, size) in zip(spec().windowsPaths, genuineSizes) {
            let target = WindowsPath.toUnix(path, prefix: prefix)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if size >= 0 {
                try Data(count: size).write(to: target)
                targets.append(target)
            }
        }
        return Fixture(prefix: prefix, stub: stub, targets: targets)
    }

    @Test func replacesGenuineServicesAndBacksThemUp() throws {
        let fx = try fixture(genuineSizes: [2_000_000, 2_000_000])
        defer { try? FileManager.default.removeItem(at: fx.prefix) }

        try SteamServiceStub.install(spec: spec(), prefix: fx.prefix, stubResource: fx.stub)

        for target in fx.targets {
            #expect(try Data(contentsOf: target).count == 4096) // now the stub
            let backup = target.appendingPathExtension("real")
            #expect(try Data(contentsOf: backup).count == 2_000_000) // genuine backed up
        }
    }

    @Test func skipsMissingTargets() throws {
        // Only the bin/ copy exists (Common Files not created until first run).
        let fx = try fixture(genuineSizes: [2_000_000, -1])
        defer { try? FileManager.default.removeItem(at: fx.prefix) }

        try SteamServiceStub.install(spec: spec(), prefix: fx.prefix, stubResource: fx.stub)

        #expect(try Data(contentsOf: fx.targets[0]).count == 4096)
        let commonFiles = WindowsPath.toUnix(spec().windowsPaths[1], prefix: fx.prefix)
        #expect(!FileManager.default.fileExists(atPath: commonFiles.path))
    }

    @Test func idempotentWhenAlreadyStubbed() throws {
        let fx = try fixture(genuineSizes: [2_000_000, 2_000_000])
        defer { try? FileManager.default.removeItem(at: fx.prefix) }
        try SteamServiceStub.install(spec: spec(), prefix: fx.prefix, stubResource: fx.stub)
        // Second pass must not clobber the .real backup with the stub.
        try SteamServiceStub.install(spec: spec(), prefix: fx.prefix, stubResource: fx.stub)

        for target in fx.targets {
            #expect(try Data(contentsOf: target.appendingPathExtension("real")).count == 2_000_000)
        }
    }

    @Test func throwsWhenStubResourceMissing() throws {
        let fx = try fixture(genuineSizes: [2_000_000, 2_000_000])
        defer { try? FileManager.default.removeItem(at: fx.prefix) }
        let missing = fx.prefix.appendingPathComponent("nope.exe")

        #expect(throws: SteamServiceStub.StubError.stubResourceMissing(name: "steamservice_stub")) {
            try SteamServiceStub.install(spec: spec(), prefix: fx.prefix, stubResource: missing)
        }
    }

    @Test func bundledStubResourceIsPackaged() {
        #expect(SteamServiceStub.bundledResource(named: "steamservice_stub") != nil)
    }
}

/// The launch path now runs the Steam binary fixups with `try` (not `try?`):
/// without the CEF wrapper Steam's UI is black, so a failed fixup is
/// launch-critical and must surface rather than launching an unusable client.
@Suite("Steam fixup failure surfaces")
struct SteamFixupFailureTests {
    @Test func applySteamBinaryFixupsPropagatesAWriteFailure() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try InstallerCatalog.bundled()
        let entry = try #require(catalog.entries.first { $0.id == "steam" })

        // A genuine (large) helper in the CEF dir so the wrapper install attempts
        // its backup+replace — then make that dir read-only so the atomic write
        // of the temp fails, exactly as a real disk/permission error would.
        let prefix = dir.appendingPathComponent("prefix")
        let cef = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/bin/cef/cef.win64")
        try FileManager.default.createDirectory(at: cef, withIntermediateDirectories: true)
        try Data(count: 1_100_000).write(to: cef.appendingPathComponent("steamwebhelper.exe"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cef.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cef.path)
        }

        #expect(throws: (any Error).self) {
            try AppInstaller.applySteamBinaryFixups(entry: entry, prefix: prefix)
        }
    }
}
