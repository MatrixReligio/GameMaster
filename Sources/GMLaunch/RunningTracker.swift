import Foundation

/// Source of truth for "is this program running" state shown in the UI.
public actor RunningTracker {
    public private(set) var runningIDs: Set<UUID> = []

    public init() {}

    public func markStarted(programID: UUID) {
        runningIDs.insert(programID)
    }

    public func markStopped(programID: UUID) {
        runningIDs.remove(programID)
    }

    public func isRunning(_ id: UUID) -> Bool {
        runningIDs.contains(id)
    }
}
