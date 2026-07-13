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

    /// A crafted PE with section addresses near UInt32.max must not trap the
    /// process on overflow (`va + size`, `rawOffset + delta`) — users drop
    /// arbitrary .exe files on the app, and a parser crash takes the whole
    /// app down.
    @Test func craftedSectionAddressOverflowReturnsNilInsteadOfCrashing() {
        var pe = FixturePE.build()
        // Layout constants for FixturePE: PE header at 0x80, optional header
        // at 0x98 (dir entry 2 = resource RVA at 0x118), section header at
        // 0x188 (virtualAddress at +12 = 0x194, rawOffset at +20 = 0x19C).
        // Point the resource RVA and the section INTO the overflow zone.
        pe.replaceSubrange(0x118 ..< 0x11C, with: UInt32(0xFFFF_FFF8).le)
        pe.replaceSubrange(0x194 ..< 0x198, with: UInt32(0xFFFF_FFF0).le)
        #expect(PEIconExtractor.extractIcoData(from: pe) == nil)

        // Same with a raw offset that overflows when the delta is added.
        var pe2 = FixturePE.build()
        pe2.replaceSubrange(0x19C ..< 0x1A0, with: UInt32(0xFFFF_FFF0).le)
        #expect(PEIconExtractor.extractIcoData(from: pe2) == nil)
    }

    /// Every truncation of a valid PE must parse to nil or an icon — never
    /// out-of-bounds. (Sweeps all interesting header boundaries.)
    @Test func truncatedPEsNeverCrash() {
        let full = FixturePE.build()
        for length in stride(from: 0, to: full.count, by: 7) {
            _ = PEIconExtractor.extractIcoData(from: full.prefix(length))
        }
        _ = PEIconExtractor.extractIcoData(from: full)
    }

    /// Icon extraction reads the whole candidate file; a giant .exe must be
    /// skipped (size gate) rather than ballooning the app's memory.
    @Test func oversizedExecutableIsSkipped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gm-pe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let huge = dir.appendingPathComponent("huge.exe")
        FileManager.default.createFile(atPath: huge.path, contents: Data("MZ".utf8))
        let handle = try FileHandle(forWritingTo: huge)
        // Sparse file just over the cap — instant to create on APFS.
        try handle.truncate(atOffset: UInt64(PEIconExtractor.maxFileBytes) + 1)
        try handle.close()

        #expect(PEIconExtractor.extractIcoData(from: huge) == nil)
    }
}
