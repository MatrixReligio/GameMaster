import Foundation

/// Extracts the embedded application icon from a Windows PE executable by
/// walking the .rsrc resource tree (RT_GROUP_ICON → RT_ICON) and assembling a
/// standard .ico container that NSImage can read directly. Pure byte parsing —
/// no wine involved, works on any .exe the user drops in.
public enum PEIconExtractor {
    private static let rtIcon: UInt32 = 3
    private static let rtGroupIcon: UInt32 = 14

    /// Anything bigger is skipped outright: icon resources live in the first
    /// megabytes, and reading a multi-gigabyte exe just to look for one would
    /// balloon memory (games ship some enormous executables).
    static let maxFileBytes = 256 * 1024 * 1024

    public static func extractIcoData(from exe: URL) -> Data? {
        let size = (try? FileManager.default.attributesOfItem(atPath: exe.path))?[.size] as? Int
        guard let size, size <= maxFileBytes else { return nil }
        // Mapped, not loaded: the parser touches only the headers and the
        // resource section, so most of the file never occupies real memory.
        guard let data = try? Data(contentsOf: exe, options: [.mappedIfSafe]) else { return nil }
        return extractIcoData(from: data)
    }

    static func extractIcoData(from data: Data) -> Data? {
        guard let pe = PEFile(data: data),
              let resourceRoot = pe.resourceSectionOffset else { return nil }

        // GROUP_ICON: first group, first language.
        guard
            let groupLeaf = firstLeaf(pe: pe, root: resourceRoot, type: rtGroupIcon),
            let group = pe.resourceData(leafOffset: groupLeaf)
        else { return nil }

        // GRPICONDIR header: reserved(2), type(2), count(2), then 14-byte entries.
        guard group.count >= 6 else { return nil }
        let count = Int(group.readU16(4))
        guard count > 0, group.count >= 6 + count * 14 else { return nil }

        struct Entry {
            var meta: Data // first 12 bytes reused in the .ico directory
            var resourceID: UInt32
            var size: UInt32
        }
        var entries: [Entry] = []
        for index in 0 ..< count {
            let base = 6 + index * 14
            let meta = group.subdata(in: group.startIndex + base ..< group.startIndex + base + 12)
            let size = group.readU32(base + 8)
            let id = UInt32(group.readU16(base + 12))
            entries.append(Entry(meta: meta, resourceID: id, size: size))
        }

        // Fetch each RT_ICON payload; keep entries whose data resolves.
        var images: [(meta: Data, payload: Data)] = []
        for entry in entries {
            guard
                let leaf = firstLeaf(pe: pe, root: resourceRoot, type: rtIcon, id: entry.resourceID),
                let payload = pe.resourceData(leafOffset: leaf)
            else { continue }
            images.append((entry.meta, payload))
        }
        guard !images.isEmpty else { return nil }

        // Assemble .ico: ICONDIR (6) + ICONDIRENTRY (16 each) + payloads.
        var ico = Data()
        ico.append(contentsOf: [0, 0, 1, 0])
        ico.append(UInt16(images.count).littleEndianData)
        var offset = 6 + images.count * 16
        for image in images {
            ico.append(image.meta.prefix(8)) // w, h, colors, reserved, planes, bpp
            ico.append(UInt32(image.payload.count).littleEndianData)
            ico.append(UInt32(offset).littleEndianData)
            offset += image.payload.count
        }
        for image in images {
            ico.append(image.payload)
        }
        return ico
    }

    /// Walks root → type dir → (id dir | first id) → first language leaf.
    private static func firstLeaf(pe: PEFile, root: Int, type: UInt32, id: UInt32? = nil) -> Int? {
        guard let typeDir = pe.directoryEntry(dirOffset: root, id: type, base: root) else { return nil }
        let idDir: Int? = if let id {
            pe.directoryEntry(dirOffset: typeDir, id: id, base: root)
        } else {
            pe.firstDirectoryEntry(dirOffset: typeDir, base: root)
        }
        guard let idDir else { return nil }
        return pe.firstDirectoryEntry(dirOffset: idDir, base: root, expectLeaf: true)
    }
}

/// Minimal PE reader: header parsing, RVA→file-offset mapping, resource tree.
private struct PEFile {
    struct Section {
        var virtualAddress: UInt32
        var virtualSize: UInt32
        var rawOffset: UInt32
        var rawSize: UInt32
    }

    let data: Data
    private var sections: [Section] = []
    private var resourceRVA: UInt32 = 0

    init?(data: Data) {
        self.data = data
        guard data.count > 0x40, data.readU16(0) == 0x5A4D else { return nil } // "MZ"
        let peOffset = Int(data.readU32(0x3C))
        guard data.count > peOffset + 24, data.readU32(peOffset) == 0x4550 else { return nil } // "PE\0\0"
        let sectionCount = Int(data.readU16(peOffset + 6))
        let optSize = Int(data.readU16(peOffset + 20))
        let optOffset = peOffset + 24
        guard data.count > optOffset + optSize, optSize >= 2 else { return nil }

        let magic = data.readU16(optOffset)
        // Data directories start at 112 (PE32+/0x20B) or 96 (PE32/0x10B).
        let dirBase = optOffset + (magic == 0x20B ? 112 : 96)
        let dirCountOffset = dirBase - 4
        guard data.count > dirBase + 3 * 8 else { return nil }
        let dirCount = data.readU32(dirCountOffset)
        guard dirCount >= 3 else { return nil }
        resourceRVA = data.readU32(dirBase + 2 * 8) // index 2 = resource table
        guard resourceRVA != 0 else { return nil }

        let sectionTable = optOffset + optSize
        for index in 0 ..< sectionCount {
            let header = sectionTable + index * 40
            guard data.count >= header + 40 else { return nil }
            sections.append(Section(
                virtualAddress: data.readU32(header + 12),
                virtualSize: data.readU32(header + 8),
                rawOffset: data.readU32(header + 20),
                rawSize: data.readU32(header + 16)
            ))
        }
    }

    /// All arithmetic in 64 bits: every field is attacker-controlled (users
    /// drop arbitrary .exe files), and crafted values near UInt32.max would
    /// otherwise trap the whole process on overflow.
    func fileOffset(rva: UInt32) -> Int? {
        let target = UInt64(rva)
        for section in sections {
            let start = UInt64(section.virtualAddress)
            let end = start + UInt64(max(section.virtualSize, section.rawSize))
            guard target >= start, target < end else { continue }
            let offset = UInt64(section.rawOffset) + (target - start)
            return offset < UInt64(data.count) ? Int(offset) : nil
        }
        return nil
    }

    var resourceSectionOffset: Int? {
        fileOffset(rva: resourceRVA)
    }

    /// Finds the ID entry in a resource directory; returns the target's file offset.
    func directoryEntry(dirOffset: Int, id: UInt32, base: Int) -> Int? {
        entries(dirOffset: dirOffset).first { $0.id == id }.flatMap { resolve(entry: $0, base: base) }
    }

    func firstDirectoryEntry(dirOffset: Int, base: Int, expectLeaf: Bool = false) -> Int? {
        guard let first = entries(dirOffset: dirOffset).first else { return nil }
        if expectLeaf, first.isDirectory { // language dirs may nest one more level
            return resolve(entry: first, base: base).flatMap {
                firstDirectoryEntry(dirOffset: $0, base: base, expectLeaf: true)
            }
        }
        return resolve(entry: first, base: base)
    }

    private struct DirEntry {
        var id: UInt32
        var offset: UInt32
        var isDirectory: Bool
    }

    private func entries(dirOffset: Int) -> [DirEntry] {
        guard data.count >= dirOffset + 16 else { return [] }
        let named = Int(data.readU16(dirOffset + 12))
        let ids = Int(data.readU16(dirOffset + 14))
        var result: [DirEntry] = []
        for index in 0 ..< (named + ids) {
            let entry = dirOffset + 16 + index * 8
            guard data.count >= entry + 8 else { break }
            let rawOffset = data.readU32(entry + 4)
            result.append(DirEntry(
                id: data.readU32(entry),
                offset: rawOffset & 0x7FFF_FFFF,
                isDirectory: rawOffset & 0x8000_0000 != 0
            ))
        }
        return result
    }

    private func resolve(entry: DirEntry, base: Int) -> Int? {
        let target = base + Int(entry.offset)
        return target < data.count ? target : nil
    }

    /// Reads the payload behind a leaf data entry (RVA + size).
    func resourceData(leafOffset: Int) -> Data? {
        guard data.count >= leafOffset + 8 else { return nil }
        let rva = data.readU32(leafOffset)
        let size = Int(data.readU32(leafOffset + 4))
        guard size > 0, size < 32 * 1024 * 1024, let offset = fileOffset(rva: rva),
              data.count >= offset + size else { return nil }
        return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + size)
    }
}

private extension Data {
    func readU16(_ offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func readU32(_ offset: Int) -> UInt32 {
        UInt32(readU16(offset)) | (UInt32(readU16(offset + 2)) << 16)
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        withUnsafeBytes(of: littleEndian) { Data($0) }
    }
}
