import Foundation

/// Verifies that a binary is validly signed by Apple. Used before copying
/// executable code from user-supplied disk images into a runtime.
public protocol SignatureVerifying: Sendable {
    /// Throws when the binary at `url` is not signed with a certificate
    /// chain anchored at Apple's root.
    func verifyAppleSigned(_ url: URL) async throws

    /// Like `verifyAppleSigned(_:)`, but additionally pins the code's
    /// signing identifier. `anchor apple` alone accepts ANY Apple platform
    /// binary (`/usr/bin/true` included); anchor files whose identity is
    /// known must not accept a random Apple-signed file in their place.
    func verifyAppleSigned(_ url: URL, identifier: String) async throws
}

public struct SignatureVerificationError: Error, Equatable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

/// Real implementation on top of `codesign --verify -R="anchor apple"`:
/// exit 0 only when the code is intact AND its certificate chain terminates
/// at Apple's root CA. Unsigned, ad-hoc, and third-party-signed binaries
/// all fail. (Verified against Apple's libd3dshared.dylib and random bytes.)
public struct CodesignVerifier: SignatureVerifying {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    public func verifyAppleSigned(_ url: URL) async throws {
        try await verify(url, requirement: "anchor apple")
    }

    public func verifyAppleSigned(_ url: URL, identifier: String) async throws {
        // The requirement language supports exact identifier matches only
        // (no wildcards) — verified against the real D3DMetal payload.
        try await verify(url, requirement: "anchor apple and identifier \"\(identifier)\"")
    }

    private func verify(_ url: URL, requirement: String) async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--strict", "-R=\(requirement)", url.path],
            environment: nil,
            currentDirectory: nil,
            outputLine: nil
        )
        guard result.exitCode == 0 else {
            throw SignatureVerificationError(path: url.path)
        }
    }
}
