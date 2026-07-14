import Testing
@testable import GMLaunch

@Suite("RuntimeLease")
struct RuntimeLeaseTests {
    @Test func freshLeaseGrantsReadersAndHasNoWriter() {
        let lease = RuntimeLease()
        #expect(lease.isWriterHeld == false)
        #expect(lease.acquireReader())
        #expect(lease.isWriterHeld == false)
    }

    @Test func writerBlocksNewReadersUntilReleased() {
        let lease = RuntimeLease()
        #expect(lease.acquireWriter()) // no readers → succeeds
        #expect(lease.isWriterHeld)
        #expect(lease.acquireReader() == false) // refused while writer holds
        lease.releaseWriter()
        #expect(lease.isWriterHeld == false)
        #expect(lease.acquireReader()) // readers flow again
    }

    @Test func anyReaderBlocksTheWriter() {
        let lease = RuntimeLease()
        #expect(lease.acquireReader())
        #expect(lease.acquireWriter() == false) // a reader is active → refused
        lease.releaseReader()
        #expect(lease.acquireWriter()) // last reader gone → succeeds
    }

    @Test func multipleReadersCoexistAndAllMustDrainBeforeAWriter() {
        let lease = RuntimeLease()
        #expect(lease.acquireReader())
        #expect(lease.acquireReader())
        #expect(lease.acquireReader())
        #expect(lease.acquireWriter() == false)
        lease.releaseReader()
        lease.releaseReader()
        #expect(lease.acquireWriter() == false) // one reader still holds
        lease.releaseReader()
        #expect(lease.acquireWriter()) // all drained
    }

    @Test func onlyOneWriterAtATime() {
        let lease = RuntimeLease()
        #expect(lease.acquireWriter())
        #expect(lease.acquireWriter() == false)
        lease.releaseWriter()
        #expect(lease.acquireWriter())
    }

    @Test func releaseReaderNeverUnderflows() {
        let lease = RuntimeLease()
        lease.releaseReader() // no-op on zero
        #expect(lease.acquireWriter()) // still 0 readers → writer succeeds
    }
}
