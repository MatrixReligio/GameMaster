import Foundation
import GMModel
import GMSystem

/// Imports Apple's D3DMetal evaluation layers from the user-supplied
/// "Evaluation environment for Windows games" DMG into an installed runtime.
///
/// Apple's Read Me documents `mv wine wine.old; ditto redist/lib/ .`, but the
/// eval environment's `lib/wine` contains ONLY DirectX shim symlinks, not a
/// full wine tree — so moving the runtime's `wine` dir aside first would drop
/// core builtins (ntdll.so, …) and brick the runtime. We instead ditto-merge
/// `redist/lib/` on top of the existing `lib/`, which overwrites exactly the
/// D3DMetal framework and DirectX shim files while preserving every other
/// builtin. Same result (newer D3DMetal active), no brick risk.
///
/// GameMaster never downloads or bundles these libraries — the user obtains
/// the DMG from developer.apple.com with their own Apple ID.
public struct GPTKImporter: Sendable {
    private let store: RuntimeStore
    private let mounter: any DiskImageMounting
    private let runner: any ProcessRunning
    private let verifier: any SignatureVerifying

    public init(
        store: RuntimeStore,
        mounter: any DiskImageMounting,
        runner: any ProcessRunning,
        verifier: any SignatureVerifying
    ) {
        self.store = store
        self.mounter = mounter
        self.runner = runner
        self.verifier = verifier
    }

    public func importGPTK(dmg: URL, into runtimeID: String) async throws -> RuntimeDescriptor {
        let volume = try await mounter.mount(dmg: dmg)
        do {
            let descriptor = try await overlay(from: volume, into: runtimeID)
            await mounter.unmount(volume)
            return descriptor
        } catch {
            await mounter.unmount(volume)
            throw error
        }
    }

    public func importGPTK(mountedVolume: URL, into runtimeID: String) async throws -> RuntimeDescriptor {
        try await overlay(from: mountedVolume, into: runtimeID)
    }

    /// The redist root must contain `lib/external/libd3dshared.dylib` — the
    /// content signature of Apple's evaluation environment.
    static func redistLibDirectory(inVolume volume: URL) -> URL? {
        let candidates = [
            volume.appendingPathComponent("redist/lib"),
            volume.appendingPathComponent("lib")
        ]
        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("external/libd3dshared.dylib").path
            )
        }
    }

    /// Parses the evaluation-environment version out of a volume or file name,
    /// e.g. "Evaluation environment for Windows games 3.0" → "3.0".
    static func versionString(from name: String) -> String {
        let pattern = /([0-9]+\.[0-9]+(?:\.[0-9]+)?)/
        if let match = name.firstMatch(of: pattern) {
            return String(match.1)
        }
        return "imported"
    }

    private func overlay(from volume: URL, into runtimeID: String) async throws -> RuntimeDescriptor {
        guard let redistLib = Self.redistLibDirectory(inVolume: volume) else {
            throw RuntimeError.dmgLayoutUnrecognized
        }
        // The detector picks candidates by file NAME (anything in ~/Downloads
        // can match), and this overlay copies executable code into the
        // runtime that every game then loads. Verify the payload is actually
        // Apple's before a single file moves.
        do {
            try await verifier.verifyAppleSigned(
                redistLib.appendingPathComponent("external/libd3dshared.dylib")
            )
        } catch {
            throw RuntimeError.dmgSignatureInvalid
        }
        guard var descriptor = try await store.descriptor(id: runtimeID) else {
            throw RuntimeError.runtimeNotInstalled(id: runtimeID)
        }

        // <runtime>/<…>/wine/bin/wine64 → <…>/wine/lib
        let wineBinary = await store.wineBinary(for: descriptor)
        let wineRoot = wineBinary.deletingLastPathComponent().deletingLastPathComponent()
        let libDir = wineRoot.appendingPathComponent("lib", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)

        // ditto merges redist/lib/ INTO lib/: it overwrites the D3DMetal
        // framework and DirectX shims but leaves every other builtin intact,
        // preserving symlinks, permissions, and framework structure.
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [redistLib.path, libDir.path],
            environment: nil,
            currentDirectory: nil,
            outputLine: nil
        )
        guard result.exitCode == 0 else {
            throw RuntimeError.dmgLayoutUnrecognized
        }

        descriptor.gptk = .installed(version: Self.versionString(from: volume.lastPathComponent))
        try await store.save(descriptor)
        return descriptor
    }
}

/// Finds candidate Apple evaluation-environment DMGs (in ~/Downloads by
/// default) and already-mounted evaluation volumes, for the onboarding flow.
public struct GPTKDetector: Sendable {
    private let searchDirectories: [URL]
    private let volumesDirectory: URL

    public init(
        searchDirectories: [URL] = [FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first]
            .compactMap(\.self),
        volumesDirectory: URL = URL(fileURLWithPath: "/Volumes")
    ) {
        self.searchDirectories = searchDirectories
        self.volumesDirectory = volumesDirectory
    }

    public func candidateDMGs() -> [URL] {
        let fm = FileManager.default
        return searchDirectories.flatMap { dir -> [URL] in
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return children.filter { url in
                guard url.pathExtension.lowercased() == "dmg" else { return false }
                let normalized = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .lowercased()
                return normalized.contains("evaluation environment")
            }
        }
    }

    public func candidateMountedVolumes() -> [URL] {
        let fm = FileManager.default
        let volumes = (try? fm.contentsOfDirectory(at: volumesDirectory, includingPropertiesForKeys: nil)) ?? []
        return volumes.filter { GPTKImporter.redistLibDirectory(inVolume: $0) != nil }
    }
}
