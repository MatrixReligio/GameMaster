import Foundation
import Testing
@testable import GMApps

@Suite("BottleLeases")
struct BottleLeasesTests {
    @Test func freshBottleGrantsBothModes() {
        let leases = BottleLeases()
        let id = UUID()
        #expect(leases.isExclusivelyHeld(id) == false)
        #expect(leases.acquireShared(id))
        leases.releaseShared(id)
        #expect(leases.acquireExclusive(id))
    }

    @Test func exclusiveBlocksSharedUntilReleased() {
        let leases = BottleLeases()
        let id = UUID()
        #expect(leases.acquireExclusive(id))
        #expect(leases.isExclusivelyHeld(id))
        #expect(leases.acquireShared(id) == false) // launch refused while delete/install holds
        leases.releaseExclusive(id)
        #expect(leases.isExclusivelyHeld(id) == false)
        #expect(leases.acquireShared(id))
    }

    @Test func sharedBlocksExclusiveUntilAllReleased() {
        let leases = BottleLeases()
        let id = UUID()
        #expect(leases.acquireShared(id))
        #expect(leases.acquireShared(id)) // two programs can run in one bottle
        #expect(leases.acquireExclusive(id) == false) // delete refused while launches run
        leases.releaseShared(id)
        #expect(leases.acquireExclusive(id) == false) // one launch still running
        leases.releaseShared(id)
        #expect(leases.acquireExclusive(id)) // all drained
    }

    @Test func onlyOneExclusiveAtATime() {
        let leases = BottleLeases()
        let id = UUID()
        #expect(leases.acquireExclusive(id))
        #expect(leases.acquireExclusive(id) == false) // install vs delete on one bottle
        leases.releaseExclusive(id)
        #expect(leases.acquireExclusive(id))
    }

    @Test func differentBottlesAreIndependent() {
        let leases = BottleLeases()
        let bottleA = UUID()
        let bottleB = UUID()
        #expect(leases.acquireExclusive(bottleA))
        // A being deleted must not block operations on B.
        #expect(leases.acquireShared(bottleB))
        #expect(leases.acquireExclusive(bottleB) == false) // B's own shared blocks B's exclusive
        leases.releaseShared(bottleB)
        #expect(leases.acquireExclusive(bottleB))
    }

    @Test func releaseSharedNeverUnderflows() {
        let leases = BottleLeases()
        let id = UUID()
        leases.releaseShared(id) // no-op on an untracked bottle
        #expect(leases.acquireExclusive(id)) // still grantable
    }
}
