import Metal
import Synchronization
import Testing
@testable import DualKawaseBlur

@Test @MainActor func presentationActivityReportsOnlyEmptyToNonemptyTransitions() throws {
    let session = try makeBridgeTestSession()
    let transitions = Mutex<[Bool]>([])
    session.setPresentationActivityHandler { active in
        transitions.withLock { $0.append(active) }
    }

    let first = UUID()
    let second = UUID()
    session.registerPresenter(id: first) {}
    session.registerPresenter(id: second) {}
    session.unregisterPresenter(id: first)
    #expect(transitions.withLock { $0 } == [false, true])

    session.unregisterPresenter(id: second)
    #expect(transitions.withLock { $0 } == [false, true, false])

    session.registerPresenter(id: UUID()) {}
    session.finish()
    session.finish()
    #expect(transitions.withLock { $0 } == [false, true, false, true, false])
}

@Test @MainActor func metadataIsValueOnlyAndInvalidationRetainsLatestOutput() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let session = try SharedMetalBlurSession(source: source, device: device)
    let firstTexture = try TestTexture.impulse(device: device, width: 32, height: 32)
    source.publish(MetalBlurFrame(texture: firstTexture))
    session.renderLatest()
    defer { session.finish() }

    var firstInfo: SharedMetalBlurFrameInfo?
    for _ in 0..<300 where firstInfo == nil {
        firstInfo = session.latestCompletedFrameInfo
        if firstInfo == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    let completed = try #require(firstInfo)
    #expect(completed.sequence > 0)
    #expect(completed.pixelWidth == 32)
    #expect(completed.pixelHeight == 32)

    let consumed = Mutex(0)
    let pendingTexture = try TestTexture.impulse(device: device, width: 32, height: 32)
    source.publish(MetalBlurFrame(texture: pendingTexture) {
        consumed.withLock { $0 += 1 }
    })
    session.invalidatePendingFrames()
    session.renderLatest()

    #expect(consumed.withLock { $0 } == 1)
    #expect(session.latestCompletedFrameInfo == completed)

    let readinessEvent = try #require(device.makeSharedEvent())
    let completion = Mutex(0)
    source.publish(MetalBlurFrame(
        texture: pendingTexture,
        readiness: .sharedEvent(readinessEvent, value: 1),
        onConsumed: { completion.withLock { $0 += 1 } }
    ))
    session.renderLatest()
    session.invalidatePendingFrames()
    readinessEvent.signaledValue = 1

    for _ in 0..<300 where completion.withLock({ $0 }) == 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(completion.withLock { $0 } == 1)
    #expect(session.latestCompletedFrameInfo == completed)
}

@MainActor
private func makeBridgeTestSession() throws -> SharedMetalBlurSession {
    guard let device = MTLCreateSystemDefaultDevice() else {
        Issue.record("Metal is unavailable in this test environment.")
        throw BridgeTestError.metalUnavailable
    }
    return try SharedMetalBlurSession(source: MetalBlurFrameSource(), device: device)
}

private enum BridgeTestError: Error {
    case metalUnavailable
}
