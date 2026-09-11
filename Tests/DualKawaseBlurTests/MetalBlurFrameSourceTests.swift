import Dispatch
import Metal
import Synchronization
import Testing
@testable import DualKawaseBlur

@Test func frameCopiesShareAnExactlyOnceLease() throws {
    let releaseCount = Mutex(0)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 2, height: 2)
    let original = MetalBlurFrame(texture: texture) {
        releaseCount.withLock { $0 += 1 }
    }
    let firstCopy = original
    let secondCopy = original

    firstCopy.releaseAfterConsumption()
    secondCopy.releaseAfterConsumption()
    original.releaseAfterConsumption()

    #expect(releaseCount.withLock { $0 } == 1)
}

@Test func framePreservesTextureAndReadiness() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 2, height: 2)
    let event = try #require(device.makeSharedEvent())
    let frame = MetalBlurFrame(
        texture: texture,
        readiness: .sharedEvent(event, value: 42)
    )

    #expect(frame.texture === texture)
    switch frame.readiness {
    case .ready:
        Issue.record("Expected shared-event readiness")
    case let .sharedEvent(actualEvent, value):
        #expect(actualEvent === event)
        #expect(value == 42)
    }

    frame.releaseAfterConsumption()
}

@Test func replacingAndFinishingReleaseEveryFrameExactlyOnce() throws {
    let releaseCount = Mutex(0)
    let source = MetalBlurFrameSource()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 2, height: 2)
    source.publish(MetalBlurFrame(texture: texture) {
        releaseCount.withLock { $0 += 1 }
    })
    source.publish(MetalBlurFrame(texture: texture) {
        releaseCount.withLock { $0 += 1 }
    })

    let taken = try #require(source.takeLatest())
    taken.releaseAfterConsumption()
    taken.releaseAfterConsumption()
    source.finish()

    #expect(releaseCount.withLock { $0 } == 2)
}

@Test func republishingAFrameCopyDoesNotReleaseItsSharedLeaseEarly() throws {
    let releaseCount = Mutex(0)
    let source = MetalBlurFrameSource()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 2, height: 2)
    let frame = MetalBlurFrame(texture: texture) {
        releaseCount.withLock { $0 += 1 }
    }

    source.publish(frame)
    source.publish(frame)

    #expect(releaseCount.withLock { $0 } == 0)
    let taken = try #require(source.takeLatest())
    taken.releaseAfterConsumption()
    #expect(releaseCount.withLock { $0 } == 1)
}

@Test func republishingAnInFlightFrameCannotMakeDiscardReleaseItEarly() throws {
    let releaseCount = Mutex(0)
    let source = MetalBlurFrameSource()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 2, height: 2)
    let frame = MetalBlurFrame(texture: texture) {
        releaseCount.withLock { $0 += 1 }
    }

    source.publish(frame)
    let inFlight = try #require(source.takeLatest())
    source.publish(frame)
    source.discardPendingFrame()

    #expect(releaseCount.withLock { $0 } == 0)
    inFlight.releaseAfterConsumption()
    #expect(releaseCount.withLock { $0 } == 1)
}

@Test func republishingAnInFlightFrameCannotMakeFinishReleaseItEarly() throws {
    let inFlightReleaseCount = Mutex(0)
    let futureReleaseCount = Mutex(0)
    let source = MetalBlurFrameSource()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 2, height: 2)
    let frame = MetalBlurFrame(texture: texture) {
        inFlightReleaseCount.withLock { $0 += 1 }
    }

    source.publish(frame)
    let inFlight = try #require(source.takeLatest())
    source.publish(frame)
    source.finish()
    source.publish(MetalBlurFrame(texture: texture) {
        futureReleaseCount.withLock { $0 += 1 }
    })

    #expect(inFlightReleaseCount.withLock { $0 } == 0)
    #expect(futureReleaseCount.withLock { $0 } == 1)
    inFlight.releaseAfterConsumption()
    #expect(inFlightReleaseCount.withLock { $0 } == 1)
}

@Test func publishAfterFinishReleasesImmediately() throws {
    let releaseCount = Mutex(0)
    let source = MetalBlurFrameSource()
    source.finish()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 1, height: 1)

    source.publish(MetalBlurFrame(texture: texture) {
        releaseCount.withLock { $0 += 1 }
    })

    #expect(releaseCount.withLock { $0 } == 1)
    #expect(source.takeLatest() == nil)
}

@Test func discardPendingFrameKeepsSourceOpen() throws {
    let releaseCount = Mutex(0)
    let source = MetalBlurFrameSource()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 1, height: 1)
    source.publish(MetalBlurFrame(texture: texture) {
        releaseCount.withLock { $0 += 1 }
    })

    source.discardPendingFrame()
    #expect(releaseCount.withLock { $0 } == 1)
    #expect(source.takeLatest() == nil)

    source.publish(MetalBlurFrame(texture: texture) {
        releaseCount.withLock { $0 += 1 }
    })
    let next = try #require(source.takeLatest())
    next.releaseAfterConsumption()
    source.finish()

    #expect(releaseCount.withLock { $0 } == 2)
}

@Test func concurrentPublishingAndTakingReleasesAllFrames() throws {
    let iterationCount = 1_000
    let releaseCount = Mutex(0)
    let source = MetalBlurFrameSource()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 1, height: 1)
    let frames = (0..<iterationCount).map { _ in
        MetalBlurFrame(texture: texture) {
            releaseCount.withLock { $0 += 1 }
        }
    }

    DispatchQueue.concurrentPerform(iterations: iterationCount) { iteration in
        source.publish(frames[iteration])

        if iteration.isMultiple(of: 2) {
            source.takeLatest()?.releaseAfterConsumption()
        }
    }

    source.finish()

    #expect(releaseCount.withLock { $0 } == iterationCount)
    #expect(source.takeLatest() == nil)
}
