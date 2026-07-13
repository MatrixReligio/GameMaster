import Foundation
import Testing

/// Repo-level supply-chain pins. The release workflow runs with the EdDSA
/// appcast key in scope — every dependency it pulls must be pinned to
/// content, not to a floating tag someone else can move.
@Suite("Supply chain pins")
struct SupplyChainTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath) // Tests/GMSystemTests/SupplyChainTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// project.yml must pin Sparkle to an exact version, and the committed
    /// Package.resolved must agree (down to a revision hash).
    @Test func sparkleIsPinnedExactlyAndResolvedFileAgrees() throws {
        let projectYML = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8
        )
        let match = try #require(
            projectYML.firstMatch(of: /exactVersion: "([0-9.]+)"/),
            "project.yml must pin Sparkle with exactVersion"
        )
        let pinned = String(match.1)

        let resolvedURL = repoRoot.appendingPathComponent(
            "GameMaster.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        let resolved = try JSONSerialization.jsonObject(
            with: Data(contentsOf: resolvedURL)
        ) as? [String: Any]
        let pins = try #require(resolved?["pins"] as? [[String: Any]])
        let sparkle = try #require(pins.first { ($0["identity"] as? String) == "sparkle" })
        let state = try #require(sparkle["state"] as? [String: Any])
        #expect(state["version"] as? String == pinned)
        #expect((state["revision"] as? String)?.count == 40)
    }

    /// The workflow downloads generate_appcast and runs it next to the
    /// appcast private key — the tarball must be checksum-verified.
    @Test func releaseWorkflowVerifiesSparkleToolChecksum() throws {
        let yml = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )
        #expect(yml.contains("shasum -a 256 -c"))
    }

    /// Every third-party action must be pinned to a full commit SHA —
    /// floating major tags (@v7) re-resolve on someone else's push.
    @Test func workflowActionsArePinnedToCommitSHAs() throws {
        for workflow in ["ci.yml", "release.yml"] {
            let yml = try String(
                contentsOf: repoRoot.appendingPathComponent(".github/workflows/\(workflow)"),
                encoding: .utf8
            )
            for line in yml.split(separator: "\n") where line.contains("uses:") {
                #expect(
                    line.firstMatch(of: /uses: [^@\s]+@[0-9a-f]{40}/) != nil,
                    "unpinned action in \(workflow): \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
        }
    }

    /// XcodeGen generates the project that gets signed; a floating
    /// `brew install` version could change build inputs. Both workflows that
    /// generate the project must download a pinned version and checksum it.
    @Test func workflowsPinXcodeGenWithChecksum() throws {
        for workflow in ["ci.yml", "release.yml"] {
            let yml = try String(
                contentsOf: repoRoot.appendingPathComponent(".github/workflows/\(workflow)"),
                encoding: .utf8
            )
            #expect(
                !yml.contains("brew install xcodegen"),
                "\(workflow) still brew-installs a floating XcodeGen"
            )
            #expect(
                yml.contains("XCODEGEN_SHA256"),
                "\(workflow) does not checksum-pin XcodeGen"
            )
        }
    }
}
