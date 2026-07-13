import Foundation
import GMModel
import Testing
@testable import GMBottles

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gm-bottles-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("BottleStore")
struct BottleStoreTests {
    @Test func createPersistsBottleWithPrefixDirectory() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(root: root)

        let bottle = try await store.create(name: "我的游戏瓶", runtimeID: "gptk-3.0-3")
        #expect(bottle.name == "我的游戏瓶")
        #expect(bottle.runtimeID == "gptk-3.0-3")

        let prefix = await store.prefixDirectory(of: bottle)
        #expect(FileManager.default.fileExists(atPath: prefix.path))
        #expect(prefix.lastPathComponent == "prefix")

        let listed = try await store.list()
        #expect(listed == [bottle])
    }

    @Test func saveUpdatesAndDeleteRemoves() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(root: root)

        var bottle = try await store.create(name: "A", runtimeID: nil)
        bottle.settings.metalHUD = true
        bottle.programs.append(Program(name: "Steam", windowsPath: "C:\\steam.exe"))
        try await store.save(bottle)
        #expect(try await store.list() == [bottle])

        try await store.delete(id: bottle.id)
        #expect(try await store.list().isEmpty)
        let dir = await store.directory(of: bottle)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func listSkipsCorruptEntries() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(root: root)
        _ = try await store.create(name: "OK", runtimeID: nil)

        let corrupt = root.appendingPathComponent("bottles/corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: corrupt.appendingPathComponent("bottle.json"))

        let listed = try await store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "OK")
    }

    /// Corrupt metadata must not vanish silently: the listing names the bad
    /// file so the UI can tell the user (the bottle's prefix — the games —
    /// is still on disk and recoverable).
    @Test func listingReportsCorruptEntries() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(root: root)
        _ = try await store.create(name: "OK", runtimeID: nil)

        let corrupt = root.appendingPathComponent("bottles/corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let badFile = corrupt.appendingPathComponent("bottle.json")
        try Data("not json".utf8).write(to: badFile)

        let listing = try await store.listing()
        #expect(listing.bottles.count == 1)
        // /var vs /private/var: compare with symlinks resolved.
        #expect(listing.corruptFiles.map { $0.resolvingSymlinksInPath() }
            == [badFile.resolvingSymlinksInPath()])
        // The corrupt file is reported, never deleted.
        #expect(FileManager.default.fileExists(atPath: badFile.path))
    }

    /// A long install must not clobber changes made while it ran: `update`
    /// reads the current state inside the actor, so a rename saved mid-install
    /// and the installer's own field changes both survive.
    @Test func updateAppliesChangesOnFreshStateNotStaleSnapshot() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(root: root)
        let created = try await store.create(name: "游戏瓶", runtimeID: "gptk")

        // User renames the bottle while an installer still holds `created`.
        _ = try await store.update(id: created.id) { $0.name = "Renamed" }

        // Installer finishes with only ITS fields — from the stale snapshot's
        // point of view — via update, not a whole-value save.
        let program = Program(name: "Steam", windowsPath: "C:\\steam.exe")
        let final = try await store.update(id: created.id) { bottle in
            bottle.runtimeID = "sikarugir"
            bottle.programs.append(program)
        }

        #expect(final.name == "Renamed")
        #expect(final.runtimeID == "sikarugir")
        #expect(final.programs == [program])
        #expect(try await store.list() == [final])
    }

    /// Deleting a bottle mid-install must not let the install's final write
    /// resurrect it as a ghost (bottle.json without a live prefix).
    @Test func updateThrowsForDeletedBottleAndDoesNotRecreate() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(root: root)
        let bottle = try await store.create(name: "Doomed", runtimeID: nil)
        try await store.delete(id: bottle.id)

        await #expect(throws: BottleError.bottleNotFound(bottle.id)) {
            _ = try await store.update(id: bottle.id) { $0.name = "Ghost" }
        }
        let dir = await store.directory(of: bottle)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(try await store.list().isEmpty)
    }

    @Test func saveRefusesToRecreateDeletedBottle() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(root: root)
        let bottle = try await store.create(name: "Doomed", runtimeID: nil)
        try await store.delete(id: bottle.id)

        await #expect(throws: BottleError.bottleNotFound(bottle.id)) {
            try await store.save(bottle)
        }
        let dir = await store.directory(of: bottle)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}

@Suite("EnvironmentComposer")
struct EnvironmentComposerTests {
    private let prefix = URL(fileURLWithPath: "/tmp/bottles/x/prefix")
    private let gptkRuntime = RuntimeDescriptor(
        id: "gptk",
        displayVersion: "GPTK",
        wineBinaryRelativePath: "wine/bin/wine64",
        gptk: .installed(version: "3.0")
    )
    private let plainRuntime = RuntimeDescriptor(
        id: "plain",
        displayVersion: "Wine",
        wineBinaryRelativePath: "wine/bin/wine64",
        gptk: .none
    )

    private func bottle(_ mutate: (inout BottleSettings) -> Void = { _ in }) -> Bottle {
        var settings = BottleSettings()
        mutate(&settings)
        return Bottle(name: "T", settings: settings)
    }

    @Test func baseEnvironment() {
        let env = EnvironmentComposer.environment(for: bottle(), prefix: prefix, runtime: gptkRuntime)
        #expect(env["WINEPREFIX"] == "/tmp/bottles/x/prefix")
        #expect(env["WINEDEBUG"] == "-all")
        #expect(env["WINEESYNC"] == "1")
        #expect(env["WINEMSYNC"] == nil)
        #expect(env["MTL_HUD_ENABLED"] == nil)
        #expect(env["ROSETTA_ADVERTISE_AVX"] == nil)
    }

    @Test func gptkEnablesDllOverrides() {
        let env = EnvironmentComposer.environment(for: bottle(), prefix: prefix, runtime: gptkRuntime)
        #expect(env["WINEDLLOVERRIDES"] == "d3d9,d3d10core,d3d11,d3d12,d3d12core,dxgi=n,b")
    }

    @Test func backendOffDisablesDllOverrides() {
        let env = EnvironmentComposer.environment(
            for: bottle { $0.dxBackend = .off },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(env["WINEDLLOVERRIDES"] == nil)
    }

    @Test func runtimeWithoutGPTKHasNoDllOverrides() {
        let env = EnvironmentComposer.environment(for: bottle(), prefix: prefix, runtime: plainRuntime)
        #expect(env["WINEDLLOVERRIDES"] == nil)
    }

    /// DXMT ships as wine *builtins*; a `d3d11,…=n,b` override would make wine
    /// look for native DLLs and bypass them. A DXMT runtime must therefore get
    /// NO DirectX overrides even though it does translate D3D to Metal.
    @Test func dxmtRuntimeGetsNoDllOverrides() {
        let dxmtRuntime = RuntimeDescriptor(
            id: "sikarugir-10.0-6-dxmt-0.80",
            displayVersion: "Sikarugir 10.0-6 + DXMT 0.80",
            wineBinaryRelativePath: "wswine.bundle/bin/wine",
            gptk: .none,
            dxmt: .installed(version: "0.80")
        )
        let env = EnvironmentComposer.environment(for: bottle(), prefix: prefix, runtime: dxmtRuntime)
        #expect(env["WINEDLLOVERRIDES"] == nil)
    }

    /// MetalFX upscaling maps to the layer the runtime actually uses: DXMT's
    /// spatial swapchain upscaler on DXMT runtimes, D3DMetal's env on GPTK.
    @Test func metalFXMapsToActiveTranslationLayer() {
        let dxmtRuntime = RuntimeDescriptor(
            id: "sikarugir-10.0-6-dxmt-0.80",
            displayVersion: "Sikarugir 10.0-6 + DXMT 0.80",
            wineBinaryRelativePath: "wswine.bundle/bin/wine",
            gptk: .none,
            dxmt: .installed(version: "0.80")
        )
        let dxmtEnv = EnvironmentComposer.environment(
            for: bottle { $0.metalFX = true },
            prefix: prefix,
            runtime: dxmtRuntime
        )
        #expect(dxmtEnv["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
        #expect(dxmtEnv["D3DM_ENABLE_METALFX"] == nil)

        let gptkEnv = EnvironmentComposer.environment(
            for: bottle { $0.metalFX = true },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(gptkEnv["D3DM_ENABLE_METALFX"] == "1")
        #expect(gptkEnv["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)

        let off = EnvironmentComposer.environment(for: bottle(), prefix: prefix, runtime: dxmtRuntime)
        #expect(off["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
    }

    @Test func syncModes() {
        let msync = EnvironmentComposer.environment(
            for: bottle { $0.sync = .msync },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(msync["WINEMSYNC"] == "1")
        #expect(msync["WINEESYNC"] == nil)

        let none = EnvironmentComposer.environment(
            for: bottle { $0.sync = .none },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(none["WINEESYNC"] == nil)
        #expect(none["WINEMSYNC"] == nil)
    }

    @Test func togglesMapToEnvironment() {
        let env = EnvironmentComposer.environment(
            for: bottle {
                $0.metalHUD = true
                $0.advertiseAVX = true
            },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(env["MTL_HUD_ENABLED"] == "1")
        #expect(env["ROSETTA_ADVERTISE_AVX"] == "1")
    }

    @Test func extraEnvironmentWinsLast() {
        let env = EnvironmentComposer.environment(
            for: bottle {
                $0.extraEnvironment = ["WINEDEBUG": "+d3d", "MY_VAR": "7"]
            },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(env["WINEDEBUG"] == "+d3d")
        #expect(env["MY_VAR"] == "7")
    }

    private let dxmtRuntime = RuntimeDescriptor(
        id: "sikarugir-10.0-6-dxmt-0.80",
        displayVersion: "Sikarugir 10.0-6 + DXMT 0.80",
        wineBinaryRelativePath: "wswine.bundle/bin/wine",
        gptk: .none,
        dxmt: .installed(version: "0.80")
    )

    /// The MetalFX quality knob only means something while MetalFX is upscaling,
    /// so the factor reaches DXMT_CONFIG only when MetalFX is also on. Integral
    /// factors serialize without a trailing ".0" (2.0 → "2").
    @Test func metalFXFactorGoesToDXMTConfigWhenUpscaling() {
        let env = EnvironmentComposer.environment(
            for: bottle { $0.metalFX = true
                $0.metalFXUpscaleFactor = 1.5
            },
            prefix: prefix,
            runtime: dxmtRuntime
        )
        #expect(env["DXMT_CONFIG"] == "d3d11.metalSpatialUpscaleFactor=1.5")
    }

    @Test func metalFXFactorIgnoredWhenMetalFXOff() {
        let env = EnvironmentComposer.environment(
            for: bottle { $0.metalFX = false
                $0.metalFXUpscaleFactor = 1.5
            },
            prefix: prefix,
            runtime: dxmtRuntime
        )
        #expect(env["DXMT_CONFIG"] == nil)
    }

    @Test func maxFrameRateGoesToDXMTConfig() {
        let env = EnvironmentComposer.environment(
            for: bottle { $0.maxFrameRate = 120 },
            prefix: prefix,
            runtime: dxmtRuntime
        )
        #expect(env["DXMT_CONFIG"] == "d3d11.preferredMaxFrameRate=120")
    }

    /// Keys are emitted in a stable (alphabetical) order so the value is
    /// deterministic and testable.
    @Test func bothDXMTKnobsComposeSortedAndSemicolonSeparated() {
        let env = EnvironmentComposer.environment(
            for: bottle { $0.metalFX = true
                $0.metalFXUpscaleFactor = 2.0
                $0.maxFrameRate = 60
            },
            prefix: prefix,
            runtime: dxmtRuntime
        )
        #expect(env["DXMT_CONFIG"] == "d3d11.metalSpatialUpscaleFactor=2;d3d11.preferredMaxFrameRate=60")
    }

    /// GPTK bottles don't run DXMT, so its config keys must never be emitted there.
    @Test func gptkRuntimeIgnoresDXMTKnobs() {
        let env = EnvironmentComposer.environment(
            for: bottle { $0.metalFX = true
                $0.metalFXUpscaleFactor = 1.5
                $0.maxFrameRate = 90
            },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(env["DXMT_CONFIG"] == nil)
    }

    /// A user who hand-writes DXMT_CONFIG in the advanced field keeps every key
    /// they set; the structured knobs merge in, and the user's explicit value
    /// wins on a conflict (the advanced field is the expert escape hatch).
    @Test func userDXMTConfigMergesAndWinsOnConflict() {
        let env = EnvironmentComposer.environment(
            for: bottle {
                $0.metalFX = true
                $0.metalFXUpscaleFactor = 2.0
                $0.maxFrameRate = 120
                $0.extraEnvironment = ["DXMT_CONFIG": "d3d11.preferredMaxFrameRate=240;dxgi.forceSDR=True"]
            },
            prefix: prefix,
            runtime: dxmtRuntime
        )
        #expect(env["DXMT_CONFIG"]
            == "d3d11.metalSpatialUpscaleFactor=2;d3d11.preferredMaxFrameRate=240;dxgi.forceSDR=True")
    }

    /// With no knobs set and no user override, DXMT_CONFIG stays unset so the
    /// runtime keeps its own defaults.
    @Test func noDXMTConfigWhenNothingSet() {
        let env = EnvironmentComposer.environment(for: bottle(), prefix: prefix, runtime: dxmtRuntime)
        #expect(env["DXMT_CONFIG"] == nil)
    }
}

@Suite("RegistryTweaks")
struct RegistryTweaksTests {
    @Test func retinaRegContent() {
        // Retina rendering needs matching 2x Windows DPI (192), or every UI
        // element draws at half size (tiny fonts).
        let on = RegistryTweaks.retinaRegContent(enabled: true)
        #expect(on == """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="y"

        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "LogPixels"=dword:000000c0

        """)
        let off = RegistryTweaks.retinaRegContent(enabled: false)
        #expect(off.contains("\"RetinaMode\"=\"n\""))
        // Non-retina restores the standard 96 DPI.
        #expect(off.contains("\"LogPixels\"=dword:00000060"))
    }
}

@Suite("Compatibility toggles")
struct CompatibilityEnvTests {
    private let prefix = URL(fileURLWithPath: "/tmp/bottles/x/prefix")
    private let gptkRuntime = RuntimeDescriptor(
        id: "gptk",
        displayVersion: "GPTK",
        wineBinaryRelativePath: "wine/bin/wine64",
        gptk: .installed(version: "3.0")
    )

    private func bottle(_ mutate: (inout BottleSettings) -> Void) -> Bottle {
        var settings = BottleSettings()
        mutate(&settings)
        return Bottle(name: "T", settings: settings)
    }

    @Test func dxrDefaultsToAppleAutodetect() {
        let env = EnvironmentComposer.environment(
            for: bottle { _ in },
            prefix: prefix,
            runtime: gptkRuntime
        )
        // nil = let Apple's own M1/M2-vs-M3 default apply; don't set the var.
        #expect(env["D3DM_SUPPORT_DXR"] == nil)
    }

    @Test func dxrOverrideSetsExplicitValue() {
        let on = EnvironmentComposer.environment(
            for: bottle { $0.dxrOverride = true },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(on["D3DM_SUPPORT_DXR"] == "1")
        let off = EnvironmentComposer.environment(
            for: bottle { $0.dxrOverride = false },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(off["D3DM_SUPPORT_DXR"] == "0")
    }

    @Test func metalFXTogglesDLSSConversion() {
        let env = EnvironmentComposer.environment(
            for: bottle { $0.metalFX = true },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(env["D3DM_ENABLE_METALFX"] == "1")
        let defaultEnv = EnvironmentComposer.environment(
            for: bottle { _ in },
            prefix: prefix,
            runtime: gptkRuntime
        )
        #expect(defaultEnv["D3DM_ENABLE_METALFX"] == nil)
    }
}
