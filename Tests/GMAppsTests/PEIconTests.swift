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

    /// A resource directory entry that points back at its own directory
    /// forms a cycle; the walker must bail out instead of recursing until
    /// the stack overflows (users drop arbitrary .exe files on the app).
    @Test func selfReferencingResourceDirectoryReturnsNilInsteadOfHanging() {
        var pe = FixturePE.build()
        // FixturePE layout: .rsrc at file offset 0x400; the GROUP_ICON id
        // directory ("idGroup") sits at +0x68 and its first entry's offset
        // field at +0x68+16+4 → file 0x47C. Point it back at idGroup itself
        // with the directory bit set.
        pe.replaceSubrange(0x47C ..< 0x480, with: (UInt32(0x68) | 0x8000_0000).le)
        #expect(PEIconExtractor.extractIcoData(from: pe) == nil)

        // Two directories pointing at each other must terminate too.
        var pe2 = FixturePE.build()
        // typeGroup at +0x38: entry offset field at +0x38+16+4 → 0x44C.
        // idGroup's entry (0x47C) points back at typeGroup (+0x38).
        pe2.replaceSubrange(0x47C ..< 0x480, with: (UInt32(0x38) | 0x8000_0000).le)
        #expect(PEIconExtractor.extractIcoData(from: pe2) == nil)
    }

    /// A GRPICONDIR claiming thousands of entries must not produce an
    /// unbounded .ico — the assembled output is capped.
    @Test func excessiveIconCountIsBounded() throws {
        let pe = FixturePE.build(groupIconEntryCount: 1_000)
        let ico = try #require(PEIconExtractor.extractIcoData(from: pe))
        let count = Int(ico[ico.startIndex + 4]) | (Int(ico[ico.startIndex + 5]) << 8)
        #expect(count <= 64)
    }

    /// Many entries referencing a large payload must not balloon the output
    /// past the total byte budget (payload amplification).
    @Test func excessiveTotalIconBytesAreBounded() {
        let pe = FixturePE.build(groupIconEntryCount: 24, iconPayload: Data(count: 1 << 20))
        let ico = PEIconExtractor.extractIcoData(from: pe)
        #expect((ico?.count ?? 0) <= 16 * 1024 * 1024 + 4096)
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
