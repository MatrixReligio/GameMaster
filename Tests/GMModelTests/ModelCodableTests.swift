import Foundation
import Testing
@testable import GMModel

@Suite("BottleSettings defaults")
struct BottleSettingsDefaultsTests {
    @Test func defaultsMatchSpec() {
        let settings = BottleSettings()
        #expect(settings.dxBackend == .auto)
        #expect(settings.retinaMode == true)
        #expect(settings.sync == .esync)
        #expect(settings.metalHUD == false)
        #expect(settings.advertiseAVX == false)
        #expect(settings.extraEnvironment.isEmpty)
    }

    /// The DXMT tuning knobs are opt-in: nil means "use the runtime's own
    /// default" (spatial factor 2.0, uncapped), so a fresh bottle changes
    /// nothing about how DXMT behaves.
    @Test func dxmtTuningDefaultsToRuntimeDefault() {
        let settings = BottleSettings()
        #expect(settings.metalFXUpscaleFactor == nil)
        #expect(settings.maxFrameRate == nil)
    }
}

@Suite("Codable round-trips")
struct ModelCodableTests {
    @Test func bottleRoundTrip() throws {
        let program = Program(
            name: "Steam",
            windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe",
            arguments: ["-allosarches", "-cef-force-32bit"],
            environment: ["FOO": "bar"],
            pinned: true
        )
        var bottle = Bottle(name: "我的游戏瓶")
        bottle.runtimeID = "gptk-3.0-3"
        bottle.programs = [program]
        bottle.settings.sync = .msync
        bottle.settings.extraEnvironment = ["X": "1"]
        bottle.settings.metalFXUpscaleFactor = 1.5
        bottle.settings.maxFrameRate = 120

        let data = try JSONEncoder().encode(bottle)
        let decoded = try JSONDecoder().decode(Bottle.self, from: data)
        #expect(decoded == bottle)
        #expect(decoded.settings.metalFXUpscaleFactor == 1.5)
        #expect(decoded.settings.maxFrameRate == 120)
        #expect(decoded.schemaVersion == 1)
    }

    /// bottle.json written before these knobs existed has neither key; they
    /// must decode to nil (runtime default), not fail the whole bottle.
    @Test func dxmtTuningKeysMissingDecodeToNil() throws {
        let json = """
        {"dxBackend": "auto", "sync": "msync", "metalFX": true}
        """
        let settings = try JSONDecoder().decode(BottleSettings.self, from: Data(json.utf8))
        #expect(settings.metalFXUpscaleFactor == nil)
        #expect(settings.maxFrameRate == nil)
    }

    @Test func runtimeDescriptorRoundTrip() throws {
        let descriptor = RuntimeDescriptor(
            id: "gptk-3.0-3",
            displayVersion: "GPTK 3.0-3",
            wineBinaryRelativePath: "Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64",
            gptk: .installed(version: "3.0")
        )
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(RuntimeDescriptor.self, from: data)
        #expect(decoded == descriptor)

        let none = RuntimeDescriptor(
            id: "plain-wine",
            displayVersion: "Wine 10",
            wineBinaryRelativePath: "wine/bin/wine64",
            gptk: .none
        )
        let data2 = try JSONEncoder().encode(none)
        #expect(try JSONDecoder().decode(RuntimeDescriptor.self, from: data2) == none)
    }

    @Test func runtimeDescriptorDXMTRoundTrip() throws {
        let descriptor = RuntimeDescriptor(
            id: "sikarugir-10.0-6-dxmt-0.80",
            displayVersion: "Sikarugir 10.0-6 + DXMT 0.80",
            wineBinaryRelativePath: "wswine.bundle/bin/wine",
            gptk: .none,
            dxmt: .installed(version: "0.80")
        )
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(RuntimeDescriptor.self, from: data)
        #expect(decoded == descriptor)
        #expect(decoded.dxmt == .installed(version: "0.80"))
    }

    /// runtime.json files written before DXMT existed have no `dxmt` key; they
    /// must keep decoding (otherwise installed runtimes vanish from the store).
    @Test func runtimeDescriptorWithoutDXMTKeyDecodesToNone() throws {
        let json = """
        {
          "id": "wine-staging-11.10",
          "displayVersion": "Wine Staging 11.10",
          "wineBinaryRelativePath": "Wine Staging.app/Contents/Resources/wine/bin/wine",
          "gptk": {"none": {}}
        }
        """
        let decoded = try JSONDecoder().decode(RuntimeDescriptor.self, from: Data(json.utf8))
        #expect(decoded.dxmt == DXMTStatus.none)
        #expect(decoded.gptk == GPTKStatus.none)
    }
}

@Suite("Forward compatibility")
struct ForwardCompatibilityTests {
    /// A bottle.json written by a NEWER app version (extra keys, and keys we
    /// know but that version dropped) must still decode with sane defaults.
    @Test func decodesUnknownAndMissingKeys() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "6F1B0F5E-0000-4000-8000-000000000001",
          "name": "Test",
          "createdAt": 776692800,
          "futureKey": {"nested": true},
          "settings": {
            "dxBackend": "auto",
            "sync": "esync",
            "someFutureToggle": true
          },
          "programs": []
        }
        """
        let bottle = try JSONDecoder().decode(Bottle.self, from: Data(json.utf8))
        #expect(bottle.name == "Test")
        #expect(bottle.settings.retinaMode == true)
        #expect(bottle.settings.metalHUD == false)
        #expect(bottle.settings.extraEnvironment.isEmpty)
        #expect(bottle.runtimeID == nil)
    }

    /// An unrecognized enum raw value (from a future version) must fall back,
    /// not fail the whole decode.
    @Test func unknownEnumRawValuesFallBack() throws {
        let json = """
        {"dxBackend": "quantum", "sync": "hypersync"}
        """
        let settings = try JSONDecoder().decode(BottleSettings.self, from: Data(json.utf8))
        #expect(settings.dxBackend == .auto)
        #expect(settings.sync == .esync)
    }
}
