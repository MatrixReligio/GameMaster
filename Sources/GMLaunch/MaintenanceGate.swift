import Foundation

/// A tiny thread-safe flag that marks a runtime-maintenance window (a GPTK
/// import replacing the shared runtime's libraries).
///
/// `AppState` owns the maintenance lease on the main actor, but `WineLauncher`
/// runs off it, so the launcher can't read the actor-isolated lease flag
/// synchronously. This gate is the shared, lock-protected view both sides
/// agree on: AppState raises it around the import, and the launcher refuses to
/// start ANY wine process (through the single `context(for:)` choke point)
/// while it's raised — a backstop that catches every entry point, including
/// ones added later, without another scattered guard.
public final class MaintenanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    public init() {}

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    public func setActive(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        active = value
    }
}
