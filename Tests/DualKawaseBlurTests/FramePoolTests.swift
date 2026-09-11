import Dispatch
import Synchronization
import Testing
@testable import DualKawaseBlur

@Test func exhaustionDropsAndOldGenerationDoesNotReenterNewPool() throws {
    let pool = FramePool(resources: ["a", "b"])
    let first = try #require(pool.tryAcquire())
    let second = try #require(pool.tryAcquire())

    #expect(pool.tryAcquire() == nil)

    pool.replace(with: ["new"])
    first.release()
    second.release()

    let current = try #require(pool.tryAcquire())
    #expect(current.resource == "new")
    current.release()
    #expect(pool.availableCount == 1)
}

@Test func duplicateReleaseReturnsOneSlotExactlyOnce() throws {
    let pool = FramePool(resources: [42])
    let lease = try #require(pool.tryAcquire())

    lease.release()
    lease.release()

    #expect(pool.availableCount == 1)
    let returned = try #require(pool.tryAcquire())
    #expect(returned.resource == 42)
    #expect(pool.tryAcquire() == nil)
    returned.release()
}

@Test func droppingLeaseReturnsItsSlot() throws {
    let pool = FramePool(resources: ["only"])

    do {
        let lease = try #require(pool.tryAcquire())
        #expect(pool.availableCount == 0)
        withExtendedLifetime(lease) {}
    }

    #expect(pool.availableCount == 1)
}

@Test func framePoolHasCheckedSendableContract() {
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(FramePool<Int>.self)
}

@Test func concurrentAttemptsNeverDuplicateSlots() throws {
    let resources = ["a", "b", "c"]
    let pool = FramePool(resources: resources)
    let acquiredLeases = Mutex<[FramePool<String>.Lease]>([])

    DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
        guard let lease = pool.tryAcquire() else {
            return
        }

        acquiredLeases.withLock { leases in
            leases.append(lease)
        }
    }

    var leases = acquiredLeases.withLock { $0 }
    #expect((1...resources.count).contains(leases.count))
    #expect(Set(leases.map(\.slotID)).count == leases.count)
    #expect(Set(leases.map(\.resource)).count == leases.count)
    #expect(pool.availableCount == resources.count - leases.count)

    for _ in leases.count..<resources.count {
        leases.append(try #require(pool.tryAcquire()))
    }
    #expect(Set(leases.map(\.slotID)).count == resources.count)
    #expect(Set(leases.map(\.resource)) == Set(resources))
    #expect(pool.availableCount == 0)
    #expect(pool.tryAcquire() == nil)

    leases.forEach {
        $0.release()
        $0.release()
    }
    #expect(pool.availableCount == resources.count)
}
