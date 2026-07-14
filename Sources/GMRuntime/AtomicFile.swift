import Foundation

/// Atomic file placement into contended locations (the shared runtime and a
/// bottle's prefix): a copy is staged under a unique temp name beside the
/// target, then swapped in with a single atomic rename. A concurrent reader
/// sees either the old file or the new one — never a missing or half-written
/// file, as the old `removeItem` → `copyItem` sequence allowed. Because the
/// sources here are immutable and identical, two racing placers can't make this
/// throw spuriously: the loser simply finds the target already in place.
public enum AtomicFile {
    /// Places a copy of `source` at `target`, overwriting any existing file,
    /// creating intermediate directories as needed.
    public static func replace(
        at target: URL,
        withCopyOf source: URL,
        using fm: FileManager = .default
    ) throws {
        let directory = target.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).gm-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        do {
            // moveItem creates when absent but throws if the target exists;
            // replaceItemAt swaps an existing target atomically. Both are a
            // single rename under the hood, so no reader observes a gap.
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
        } catch {
            try? fm.removeItem(at: temp)
            // A concurrent placer of the same source may have won the race — a
            // target that now exists is success; only a still-missing one fails.
            if !fm.fileExists(atPath: target.path) {
                throw error
            }
        }
    }
}
