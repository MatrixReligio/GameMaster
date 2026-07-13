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

    /// The anchor file's signing identifier, read off Apple's real payload
    /// (`codesign -dvvv`); `anchor apple` alone would accept any Apple
    /// platform binary planted at the anchor path.
    static let anchorIdentifier = "com.apple.libd3dshared"

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
                redistLib.appendingPathComponent("external/libd3dshared.dylib"),
                identifier: Self.anchorIdentifier
            )
        } catch {
            throw RuntimeError.dmgSignatureInvalid
        }
        // One verified anchor is not enough: ditto copies the WHOLE
        // directory, so everything else that could reach dyld must pass too.
        try await preflightVerify(redistLib: redistLib)
        guard var descriptor = try await store.descriptor(id: runtimeID) else {
            throw RuntimeError.runtimeNotInstalled(id: runtimeID)
        }

        // <runtime>/<…>/wine/bin/wine64 → <…>/wine/lib
        let wineBinary = await store.wineBinary(for: descriptor)
        let wineRoot = wineBinary.deletingLastPathComponent().deletingLastPathComponent()
        let libDir = wineRoot.appendingPathComponent("lib", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)

        // Build the merged tree ASIDE and swap it in whole: dittoing straight
        // onto the live lib/ meant a failure mid-copy left it half old, half
        // new. Staging lives next to lib/ so the final swap is a same-volume
        // rename (replaceDirectory's backup-swap keeps a crash recoverable).
        let staging = wineRoot.appendingPathComponent(".lib.gptk-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        for source in [libDir, redistLib] {
            // ditto merges INTO the target: first call copies the current
            // lib, second overlays the D3DMetal framework and DirectX shims
            // while leaving every other builtin intact (symlinks,
            // permissions, and framework structure preserved).
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [source.path, staging.path],
                environment: nil,
                currentDirectory: nil,
                outputLine: nil
            )
            guard result.exitCode == 0 else {
                throw RuntimeError.dmgLayoutUnrecognized
            }
        }
        try RuntimeInstaller.replaceDirectory(at: libDir, with: staging)

        descriptor.gptk = .installed(version: Self.versionString(from: volume.lastPathComponent))
        try await store.save(descriptor)
        return descriptor
    }

    /// Walks the payload before anything is copied: every Mach-O (loose
    /// dylib, framework binary, extensionless executable) must be
    /// Apple-signed, and every symlink must resolve inside the payload —
    /// an escaping link would make the runtime load code from an
    /// attacker-influenced path outside the verified volume.
    private func preflightVerify(redistLib: URL) async throws {
        let fm = FileManager.default
        let root = redistLib.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(
            at: redistLib,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: []
        ) else {
            throw RuntimeError.dmgLayoutUnrecognized
        }
        var contents: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            contents.append(item)
        }
        var verified: Set<String> = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true {
                // Resolve the link target lexically against its (resolved)
                // parent — the target itself may not exist yet, and a live
                // resolve of a dangling link would let it slip through.
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: url.path) else {
                    throw RuntimeError.dmgLayoutUnrecognized
                }
                let parent = URL(
                    fileURLWithPath: url.deletingLastPathComponent().resolvingSymlinksInPath().path,
                    isDirectory: true
                )
                let target = URL(fileURLWithPath: destination, relativeTo: parent).standardizedFileURL
                guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
                    throw RuntimeError.dmgLayoutUnrecognized
                }
                continue // in-payload target is verified on its own visit
            }
            guard values?.isRegularFile == true, Self.isMachO(url) else { continue }
            guard verified.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            do {
                try await verifier.verifyAppleSigned(url)
            } catch {
                throw RuntimeError.dmgSignatureInvalid
            }
        }
    }

    /// Windows PEs (.dll) and data files are not loadable by dyld and are
    /// out of codesign's scope — only real Mach-O files need verification.
    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 4),
              head.count == 4
        else { return false }
        try? handle.close()
        let magic = head.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Self.machOMagics.contains(magic)
    }

    /// Thin (32/64-bit, both endians) and fat Mach-O magics.
    private static let machOMagics: Set<UInt32> = [
        0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA
    ]
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
