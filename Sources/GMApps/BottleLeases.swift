import Foundation

/// A single-writer / multi-reader lease PER BOTTLE, for coordinating the
/// AppState operations that act on one bottle.
///
/// Structural mutations — delete, install/migrate into a bottle — take the
/// EXCLUSIVE lease; launching/running a program takes a SHARED lease (several
/// programs run in one bottle at once). Exclusive can't be granted while any
/// shared holder is live, and vice versa, so a delete can never remove a prefix
/// out from under a launch or an install (and back).
///
/// This is the bottle-scoped sibling of `RuntimeLease` (which coordinates the
/// shared runtime). Both replace the scattered `Set<UUID>` flags
/// (busyBottleIDs / activeInstall / runningIDs …) that couldn't express lock
/// ownership, reference counts, or which operations are compatible — so every
/// round a new entry point forgot to check one of them. Every bottle entry
/// point now acquires the right lease synchronously before its first await; the
/// UI-state sets remain, but only for display, not for the safety invariant.
///
/// Lock-protected `Sendable`: acquisition happens on the main actor today, but
/// the lock keeps it correct regardless of caller isolation.
final class BottleLeases: @unchecked Sendable {
    private struct State {
        var readers = 0
        var writer = false
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    init() {}

    /// Take the exclusive lease for a delete/install/migrate. Fails while any
    /// shared holder (a launch) or another exclusive holder is live.
    func acquireExclusive(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var state = states[id] ?? State()
        if state.writer || state.readers > 0 {
            return false
        }
        state.writer = true
        states[id] = state
        return true
    }

    func releaseExclusive(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = states[id] else { return }
        state.writer = false
        store(id, state)
    }

    /// Take a shared lease for a launch/run. Fails while an exclusive holder
    /// (a delete/install) is live.
    func acquireShared(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var state = states[id] ?? State()
        if state.writer {
            return false
        }
        state.readers += 1
        states[id] = state
        return true
    }

    func releaseShared(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = states[id] else { return }
        if state.readers > 0 {
            state.readers -= 1
        }
        store(id, state)
    }

    func isExclusivelyHeld(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states[id]?.writer ?? false
    }

    /// Drop the entry entirely once idle, so the dictionary can't grow without
    /// bound across a session's bottles. Caller holds the lock.
    private func store(_ id: UUID, _ state: State) {
        if !state.writer, state.readers == 0 {
            states[id] = nil
        } else {
            states[id] = state
        }
    }
}
