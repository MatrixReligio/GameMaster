import Foundation

/// Builds a minimal-but-valid PE32+ executable containing one RT_GROUP_ICON
/// and one RT_ICON resource (a PNG payload, as modern .ico files embed).
/// Layout: DOS header → PE sig → COFF → optional header (with resource data
/// directory) → 1 section (.rsrc) → resource tree.
public enum FixturePE {
    /// 1x1 red pixel PNG.
    public static let pngIcon: Data = {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
        guard let data = Data(base64Encoded: base64) else {
            preconditionFailure("invalid fixture PNG base64")
        }
        return data
    }()

    // Byte-layout construction reads best as one sequential function.
    // swiftlint:disable:next function_body_length
    public static func build(groupIconEntryCount: Int = 1, iconPayload: Data? = nil) -> Data {
        let rsrcRVA: UInt32 = 0x1000
        var rsrc = Data()

        // Resource directory tree. All offsets are relative to .rsrc start.
        // Root dir (1 ID entry: type 14 GROUP_ICON) + second entry (type 3 ICON)
        struct DirEntrySpec {
            var id: UInt32
            var offset: UInt32
            var isDir: Bool
        }
        func directory(entries: [DirEntrySpec]) -> Data {
            var dir = Data(count: 12)
            dir.append(UInt16(0).le) // named entries
            dir.append(UInt16(entries.count).le)
            for entry in entries {
                dir.append(entry.id.le)
                dir.append((entry.isDir ? (entry.offset | 0x8000_0000) : entry.offset).le)
            }
            return dir
        }

        // Precompute layout:
        // root(16+2*8=32) → typeIconDir(24) → typeGroupDir(24) → idDir x2 (24each)
        // → langDir x2 (24 each… actually leaf data entries 16 each)
        // Simpler: compute sequentially.
        var chunks: [(name: String, data: Data)] = []
        func offset(of name: String) -> UInt32 {
            var total: UInt32 = 0
            for chunk in chunks {
                if chunk.name == name {
                    return total
                }
                total += UInt32(chunk.data.count)
            }
            fatalError("unknown chunk \(name)")
        }

        // Build ICO payloads.
        let iconData = iconPayload ?? pngIcon
        // GRPICONDIR: reserved, type=1, count; entries: w,h,colors,res,planes,bpp,size,id.
        // All entries reference the same RT_ICON id 7 — enough for tests that
        // probe count-amplification without a resource per entry.
        var group = Data()
        group.append(UInt16(0).le)
        group.append(UInt16(1).le)
        group.append(UInt16(groupIconEntryCount).le)
        for _ in 0 ..< groupIconEntryCount {
            group.append(contentsOf: [1, 1, 0, 0]) // 1x1, no palette
            group.append(UInt16(1).le) // planes
            group.append(UInt16(32).le) // bpp
            group.append(UInt32(iconData.count).le)
            group.append(UInt16(7).le) // RT_ICON resource id 7
        }

        // Chunk order (offsets computed on demand):
        chunks = [
            ("root", Data(count: 32)),
            ("typeIcon", Data(count: 24)),
            ("typeGroup", Data(count: 24)),
            ("idIcon", Data(count: 24)),
            ("idGroup", Data(count: 24)),
            ("leafIcon", Data(count: 16)),
            ("leafGroup", Data(count: 16)),
            ("icoData", iconData),
            ("groupData", group)
        ]

        // Now fill real contents with known offsets.
        var filled: [String: Data] = [:]
        filled["root"] = directory(entries: [
            DirEntrySpec(id: 3, offset: offset(of: "typeIcon"), isDir: true), // RT_ICON
            DirEntrySpec(id: 14, offset: offset(of: "typeGroup"), isDir: true) // RT_GROUP_ICON
        ])
        filled["typeIcon"] = directory(entries: [DirEntrySpec(id: 7, offset: offset(of: "idIcon"), isDir: true)])
        filled["typeGroup"] = directory(entries: [DirEntrySpec(id: 1, offset: offset(of: "idGroup"), isDir: true)])
        filled["idIcon"] = directory(entries: [DirEntrySpec(id: 1033, offset: offset(of: "leafIcon"), isDir: false)])
        filled["idGroup"] = directory(entries: [DirEntrySpec(id: 1033, offset: offset(of: "leafGroup"), isDir: false)])
        var leafIcon = Data()
        leafIcon.append((rsrcRVA + offset(of: "icoData")).le) // data RVA
        leafIcon.append(UInt32(iconData.count).le)
        leafIcon.append(UInt32(0).le)
        leafIcon.append(UInt32(0).le)
        filled["leafIcon"] = leafIcon
        var leafGroup = Data()
        leafGroup.append((rsrcRVA + offset(of: "groupData")).le)
        leafGroup.append(UInt32(group.count).le)
        leafGroup.append(UInt32(0).le)
        leafGroup.append(UInt32(0).le)
        filled["leafGroup"] = leafGroup
        filled["icoData"] = iconData
        filled["groupData"] = group

        for (name, data) in filled {
            guard let idx = chunks.firstIndex(where: { $0.name == name }) else {
                preconditionFailure("unknown chunk \(name)")
            }
            var padded = data
            if padded.count < chunks[idx].data.count {
                padded.append(Data(count: chunks[idx].data.count - padded.count))
            }
            chunks[idx].data = padded
        }
        rsrc = chunks.reduce(into: Data()) { $0.append($1.data) }

        // --- PE container ---
        let fileAlign: UInt32 = 0x200
        let rsrcFileOffset: UInt32 = 0x400
        var pe = Data()
        // DOS header: "MZ" + e_lfanew at 0x3C → 0x80
        pe.append(Data("MZ".utf8))
        pe.append(Data(count: 0x3C - 2))
        pe.append(UInt32(0x80).le)
        pe.append(Data(count: 0x80 - pe.count))
        // PE signature
        pe.append(Data("PE\0\0".utf8))
        // COFF: machine amd64, 1 section, opt header size 0xF0 (PE32+)
        pe.append(UInt16(0x8664).le)
        pe.append(UInt16(1).le) // sections
        pe.append(Data(count: 12)) // timestamp, symtab, nsyms
        pe.append(UInt16(0xF0).le) // optional header size
        pe.append(UInt16(0x22).le) // characteristics
        // Optional header PE32+
        var opt = Data()
        opt.append(UInt16(0x20B).le) // magic PE32+
        opt.append(Data(count: 110 - 2)) // up to NumberOfRvaAndSizes (offset 108)
        // Fix NumberOfRvaAndSizes at offset 108:
        opt.replaceSubrange(108 ..< 110, with: UInt16(0).le) // placeholder (not used)
        // Actually set NumberOfRvaAndSizes as UInt32 at offset 108.
        opt.replaceSubrange(108 ..< 110, with: Data(count: 2))
        opt.append(Data(count: 0)) // keep simple; we'll rebuild precisely below
        // Rebuild optional header precisely: 112 bytes fixed + 16 dirs * 8
        opt = Data(count: 0xF0)
        opt.replaceSubrange(0 ..< 2, with: UInt16(0x20B).le)
        opt.replaceSubrange(108 ..< 112, with: UInt32(16).le) // NumberOfRvaAndSizes
        // Data directory index 2 = resource table: offset 112 + 2*8 = 128
        opt.replaceSubrange(128 ..< 132, with: rsrcRVA.le)
        opt.replaceSubrange(132 ..< 136, with: UInt32(rsrc.count).le)
        pe.append(opt)
        // Section header ".rsrc"
        var sect = Data()
        sect.append(Data(".rsrc\0\0\0".utf8))
        sect.append(UInt32(rsrc.count).le) // virtual size
        sect.append(rsrcRVA.le) // virtual address
        sect.append(UInt32((UInt32(rsrc.count) + fileAlign - 1) / fileAlign * fileAlign).le) // raw size
        sect.append(rsrcFileOffset.le) // raw offset
        sect.append(Data(count: 16)) // relocs etc.
        pe.append(sect)
        // Pad to raw offset, then resource section
        pe.append(Data(count: Int(rsrcFileOffset) - pe.count))
        pe.append(rsrc)
        return pe
    }
}

public extension FixedWidthInteger {
    /// Little-endian byte serialization, shared with tests that craft
    /// malformed PE variants byte-by-byte.
    var le: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}
