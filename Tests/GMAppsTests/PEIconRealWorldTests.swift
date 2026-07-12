import AppKit
import Foundation
import Testing
@testable import GMApps

/// Opt-in integration check against a real Windows executable on this machine
/// (set GM_REAL_EXE). Skipped silently in CI.
@Suite("PEIconExtractor real-world")
struct PEIconRealWorldTests {
    @Test func extractsUsableIconFromRealExe() throws {
        guard let path = ProcessInfo.processInfo.environment["GM_REAL_EXE"] else { return }
        let ico = try #require(PEIconExtractor.extractIcoData(from: URL(fileURLWithPath: path)))
        let image = try #require(NSImage(data: ico))
        #expect(image.size.width >= 16)
        print("real exe icon: \(ico.count) bytes, size \(image.size)")
    }
}
