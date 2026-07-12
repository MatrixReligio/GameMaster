import Foundation
import GMTestSupport
import Testing
@testable import GMApps

@Suite("PEIconExtractor")
struct PEIconExtractorTests {
    @Test func extractsIcoFromPEResources() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-pe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("app.exe")
        try FixturePE.build().write(to: exe)

        let ico = try #require(PEIconExtractor.extractIcoData(from: exe))
        // .ico container: reserved=0, type=1, count=1, then our PNG payload.
        #expect(ico.prefix(4) == Data([0, 0, 1, 0]))
        #expect(ico.count > FixturePE.pngIcon.count)
        // The PNG payload must be embedded intact.
        #expect(ico.range(of: FixturePE.pngIcon) != nil)
    }

    @Test func returnsNilForNonPEFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-pe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notExe = dir.appendingPathComponent("data.exe")
        try Data("this is not a PE file at all".utf8).write(to: notExe)
        #expect(PEIconExtractor.extractIcoData(from: notExe) == nil)
        #expect(PEIconExtractor.extractIcoData(from: dir.appendingPathComponent("missing.exe")) == nil)
    }
}
