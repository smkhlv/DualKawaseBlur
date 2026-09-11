import Synchronization
import Testing
@testable import DualKawaseBlur

@Test func frameLeaseReleasesExplicitlyExactlyOnce() {
    let releaseCount = Mutex(0)
    let lease = FrameLease {
        releaseCount.withLock { $0 += 1 }
    }

    lease.release()
    lease.release()

    #expect(releaseCount.withLock { $0 } == 1)
}

@Test func frameLeaseReleasesOnDeinitialization() {
    let releaseCount = Mutex(0)

    do {
        _ = FrameLease {
            releaseCount.withLock { $0 += 1 }
        }
    }

    #expect(releaseCount.withLock { $0 } == 1)
}
