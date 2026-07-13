import Foundation
import Testing
@testable import GMSystem

/// Real codesign round-trips: the verifier must accept Apple-signed binaries
/// and reject unsigned bytes — this is the wall between "a DMG whose file
/// name matched" and "code that games will load".
@Suite("CodesignVerifier")
struct CodesignVerifierTests {
    @Test func acceptsAppleSignedBinary() async throws {
        let verifier = CodesignVerifier(runner: SubprocessRunner())
        try await verifier.verifyAppleSigned(URL(fileURLWithPath: "/usr/bin/true"))
    }

    /// `anchor apple` accepts ANY Apple platform binary (`/usr/bin/true`
    /// included). Anchor files whose identity is known get their signing
    /// identifier pinned on top, so a random Apple-signed file placed at the
    /// anchor path no longer passes.
    @Test func identifierPinRejectsOtherAppleBinaries() async throws {
        let verifier = CodesignVerifier(runner: SubprocessRunner())
        await #expect(throws: SignatureVerificationError(path: "/usr/bin/true")) {
            try await verifier.verifyAppleSigned(
                URL(fileURLWithPath: "/usr/bin/true"),
                identifier: "com.apple.libd3dshared"
            )
        }
    }

    @Test func identifierPinAcceptsMatchingBinary() async throws {
        let verifier = CodesignVerifier(runner: SubprocessRunner())
        try await verifier.verifyAppleSigned(
            URL(fileURLWithPath: "/usr/bin/true"),
            identifier: "com.apple.true"
        )
    }

    @Test func rejectsUnsignedFile() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-unsigned-\(UUID().uuidString).dylib")
        try Data((0 ..< 128).map { UInt8($0) }).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let verifier = CodesignVerifier(runner: SubprocessRunner())
        await #expect(throws: SignatureVerificationError(path: file.path)) {
            try await verifier.verifyAppleSigned(file)
        }
    }
}
