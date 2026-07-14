import Foundation

/// A single-writer / multi-reader lease over the shared Wine runtime.
///
/// Every operation that starts a Wine process takes a READER for the whole
/// operation (acquired atomically before its first await, released when the
/// command ends). A GPTK import — which replaces the runtime's libraries —
/// takes the WRITER, which succeeds only when no reader is active and no other
/// writer holds it; while the writer is held, new readers are refused.
///
/// This replaces the old "check a bool at the top of `context`" gate, which was
/// a check-then-await race: a wine op could read "not under maintenance", then
/// suspend on an actor hop while an import raised the flag and started replacing
/// `lib/`, then resume and launch anyway. Holding a reader across the whole
/// operation makes that impossible — the writer can't be granted while the
/// reader is outstanding — without depending on any UI-facing state set
/// (`launchingIDs`, `busyBottleIDs`, …) for the low-level safety invariant.
///
/// Lock-protected and `Sendable`: the reader side runs off the main actor
/// inside `WineLauncher`, the writer side on the main actor inside `AppState`.
public final class RuntimeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var readers = 0
    private var writer = false

    public init() {}

    /// Take a reader for a Wine operation. Fails (returns false) while the
    /// writer is held, so callers must refuse the operation.
    public func acquireReader() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if writer {
            return false
        }
        readers += 1
        return true
    }

    public func releaseReader() {
        lock.lock()
        defer { lock.unlock() }
        if readers > 0 {
            readers -= 1
        }
    }

    /// Take the writer for a runtime replace. Fails (returns false) while any
    /// reader is active or another writer holds it.
    public func acquireWriter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if writer || readers > 0 {
            return false
        }
        writer = true
        return true
    }

    public func releaseWriter() {
        lock.lock()
        defer { lock.unlock() }
        writer = false
    }

    /// Whether a runtime replace currently holds the writer — surfaced as
    /// `AppState.runtimeMaintenanceInProgress` for the UI and the entry guards.
    public var isWriterHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writer
    }
}
