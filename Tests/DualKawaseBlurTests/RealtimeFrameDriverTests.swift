import Metal
import Synchronization
import SwiftUI
import Testing
@testable import DualKawaseBlur

@MainActor
@Test func realtimeDriverBalancesEveryEarlyReturnAndCompletionPath() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 16, height: 16)

    for scenario in RealtimeScenario.allCases {
        let released = Mutex(0)
        let source = MetalBlurFrameSource()
        let pool = FramePool(resources: [0])
        var completion: (@Sendable (DualKawaseBlurError?) -> Void)?
        var submitted = 0

        if scenario != .noFrame {
            source.publish(MetalBlurFrame(texture: texture) {
                released.withLock { $0 += 1 }
            })
        }
        let held = scenario == .poolExhausted ? pool.tryAcquire() : nil
        let driver = RealtimeFrameDriver(
            source: source,
            pool: pool,
            nextDrawable: { scenario == .noDrawable ? nil : FakeDrawable() },
            submit: { _, _, _, handler in
                submitted += 1
                if scenario == .encodeThrows {
                    throw DualKawaseBlurError.unsupportedTexture
                }
                completion = handler
            },
            onError: nil
        )

        driver.tick()

        switch scenario {
        case .normal:
            #expect(submitted == 1)
            #expect(released.withLock { $0 } == 0)
            #expect(pool.availableCount == 0)
            completion?(nil)
        case .commandFailure:
            #expect(submitted == 1)
            completion?(.gpuExecutionFailed)
        default:
            break
        }
        held?.release()
        #expect(released.withLock { $0 } == (scenario == .noFrame ? 0 : 1))
        #expect(pool.availableCount == 1)
    }
}

@MainActor
@Test func resizeRetiresOldGenerationUntilItsCompletion() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 16, height: 16)
    let source = MetalBlurFrameSource()
    let pool = FramePool(resources: ["old"])
    var completion: (@Sendable (DualKawaseBlurError?) -> Void)?
    source.publish(MetalBlurFrame(texture: texture))
    let driver = RealtimeFrameDriver(
        source: source,
        pool: pool,
        nextDrawable: { FakeDrawable() },
        submit: { _, _, _, handler in completion = handler },
        onError: nil
    )

    driver.tick()
    pool.replace(with: ["new"])
    #expect(pool.availableCount == 1)
    completion?(nil)
    let current = try #require(pool.tryAcquire())
    #expect(current.resource == "new")
    current.release()
    #expect(pool.availableCount == 1)
}

@MainActor
@Test func teardownDiscardsPendingFrameWithoutFinishingReusableSource() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 16, height: 16)
    let released = Mutex(0)
    let source = MetalBlurFrameSource()
    source.publish(MetalBlurFrame(texture: texture) { released.withLock { $0 += 1 } })
    let driver = RealtimeFrameDriver(
        source: source,
        pool: FramePool(resources: [0]),
        nextDrawable: { FakeDrawable() },
        submit: { _, _, _, _ in },
        onError: nil
    )

    driver.teardown()
    #expect(released.withLock { $0 } == 1)
    source.publish(MetalBlurFrame(texture: texture) { released.withLock { $0 += 1 } })
    source.discardPendingFrame()
    #expect(released.withLock { $0 } == 2)
}

@MainActor
@Test func equivalentErrorsAreDeduplicatedUntilSuccess() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 16, height: 16)
    let source = MetalBlurFrameSource()
    let errors = Mutex<[DualKawaseBlurError]>([])
    var shouldFail = true
    let driver = RealtimeFrameDriver(
        source: source,
        pool: FramePool(resources: [0]),
        nextDrawable: { FakeDrawable() },
        submit: { _, _, _, completion in
            if shouldFail { throw DualKawaseBlurError.unsupportedTexture }
            completion(nil)
        },
        onError: { error in errors.withLock { $0.append(error) } }
    )

    for _ in 0..<2 {
        source.publish(MetalBlurFrame(texture: texture))
        driver.tick()
    }
    #expect(errors.withLock { $0 } == [.unsupportedTexture])

    shouldFail = false
    source.publish(MetalBlurFrame(texture: texture))
    driver.tick()
    await Task.yield()
    shouldFail = true
    source.publish(MetalBlurFrame(texture: texture))
    driver.tick()
    #expect(errors.withLock { $0 } == [.unsupportedTexture, .unsupportedTexture])
}

@MainActor
@Test func olderSuccessCannotClearANewerFailure() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 16, height: 16)
    let source = MetalBlurFrameSource()
    let errors = Mutex<[DualKawaseBlurError]>([])
    var completions: [(@Sendable (DualKawaseBlurError?) -> Void)] = []
    var throwFromNextSubmission = false
    let driver = RealtimeFrameDriver(
        source: source,
        pool: FramePool(resources: [0, 1]),
        nextDrawable: { FakeDrawable() },
        submit: { _, _, _, completion in
            if throwFromNextSubmission {
                throwFromNextSubmission = false
                throw DualKawaseBlurError.unsupportedTexture
            }
            completions.append(completion)
        },
        onError: { error in errors.withLock { $0.append(error) } }
    )

    source.publish(MetalBlurFrame(texture: texture))
    driver.tick()
    source.publish(MetalBlurFrame(texture: texture))
    driver.tick()
    completions[1](.gpuExecutionFailed)
    driver.tick()
    completions[0](nil)
    driver.tick()

    source.publish(MetalBlurFrame(texture: texture))
    driver.tick()
    throwFromNextSubmission = true
    source.publish(MetalBlurFrame(texture: texture))
    driver.tick()
    #expect(errors.withLock { $0 } == [.gpuExecutionFailed, .unsupportedTexture])
}

@MainActor
@Test func displayLifecyclePausesAndDiscardsWhenInactiveOrDetached() {
    var runningChanges: [Bool] = []
    var discards = 0
    let lifecycle = RealtimeDisplayLifecycle(
        setRunning: { runningChanges.append($0) },
        discardPending: { discards += 1 }
    )

    lifecycle.attach(isApplicationActive: true)
    lifecycle.willResignActive()
    lifecycle.didBecomeActive()
    lifecycle.detach()
    lifecycle.didBecomeActive()

    #expect(runningChanges == [true, false, true, false])
    #expect(discards == 4)
}

@Test func completionInboxOverflowRetainsNewestEventsInExactSequenceOrder() {
    let inbox = RealtimeCompletionInbox()
    inbox.record(sequence: 4, error: .gpuExecutionFailed)
    inbox.record(sequence: 2, error: nil)
    inbox.record(sequence: 5, error: .unsupportedTexture)
    inbox.record(sequence: 1, error: .metalUnavailable)
    inbox.record(sequence: 3, error: .invalidConfiguration)

    let events = inbox.drain().events.sorted { $0.sequence < $1.sequence }
    #expect(events.map(\.sequence) == [1, 3, 5])
    #expect(events.map(\.error) == [.metalUnavailable, .invalidConfiguration, .unsupportedTexture])
    #expect(inbox.drain().events.isEmpty)
}

@MainActor
@Test func becomingActiveDiscardsFramesPublishedWhileInactiveBeforeResuming() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 16, height: 16)
    let source = MetalBlurFrameSource()
    let released = Mutex(0)
    var transitions: [String] = []
    let lifecycle = RealtimeDisplayLifecycle(
        setRunning: { transitions.append($0 ? "running" : "paused") },
        discardPending: {
            transitions.append("discard")
            source.discardPendingFrame()
        }
    )

    lifecycle.attach(isApplicationActive: true)
    lifecycle.willResignActive()
    source.publish(MetalBlurFrame(texture: texture) { released.withLock { $0 += 1 } })
    transitions.removeAll()
    lifecycle.didBecomeActive()

    #expect(transitions == ["discard", "running"])
    #expect(released.withLock { $0 } == 1)
    #expect(source.takeLatest() == nil)
}

@MainActor
@Test func representableUpdateRebindsSourceAndLatestErrorCallback() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let texture = try TestTexture.empty(device: device, width: 16, height: 16)
    let oldSource = MetalBlurFrameSource()
    let newSource = MetalBlurFrameSource()
    let oldReleased = Mutex(0)
    let newReleased = Mutex(0)
    let oldErrors = Mutex<[DualKawaseBlurError]>([])
    let newErrors = Mutex<[DualKawaseBlurError]>([])
    oldSource.publish(MetalBlurFrame(texture: texture) { oldReleased.withLock { $0 += 1 } })
    let controller = MetalBlurViewController(
        source: oldSource,
        configuration: .init(),
        onError: { error in oldErrors.withLock { $0.append(error) } },
        overlay: EmptyView()
    )
    controller.loadViewIfNeeded()

    controller.update(
        source: newSource,
        configuration: .init(),
        onError: { error in newErrors.withLock { $0.append(error) } },
        overlay: EmptyView()
    )
    #expect(oldReleased.withLock { $0 } == 1)
    #expect(controller.renderView?.source === newSource)
    controller.renderView?.report(.gpuExecutionFailed)
    #expect(oldErrors.withLock { $0 }.isEmpty)
    #expect(newErrors.withLock { $0 } == [.gpuExecutionFailed])

    newSource.publish(MetalBlurFrame(texture: texture) { newReleased.withLock { $0 += 1 } })
    controller.renderView?.teardown()
    #expect(newReleased.withLock { $0 } == 1)
}

@Test func workspaceGenerationIgnoresOffsetButIncludesIterationsAndTextureShape() throws {
    let base = try WorkspaceSignature.validated(width: 100, height: 80, pixelFormat: .bgra8Unorm, configuration: .init(iterations: 3, offset: 1))
    let offsetOnly = try WorkspaceSignature.validated(width: 100, height: 80, pixelFormat: .bgra8Unorm, configuration: .init(iterations: 3, offset: 99))
    let iterations = try WorkspaceSignature.validated(width: 100, height: 80, pixelFormat: .bgra8Unorm, configuration: .init(iterations: 4, offset: 1))
    let size = try WorkspaceSignature.validated(width: 101, height: 80, pixelFormat: .bgra8Unorm, configuration: .init(iterations: 3, offset: 1))
    let format = try WorkspaceSignature.validated(width: 100, height: 80, pixelFormat: .bgra8Unorm_srgb, configuration: .init(iterations: 3, offset: 1))

    #expect(base == offsetOnly)
    #expect(base != iterations)
    #expect(base != size)
    #expect(base != format)
}

@Test func offsetOnlyWorkspaceUpdateStillValidatesTheNewOffset() {
    #expect(throws: DualKawaseBlurError.invalidConfiguration) {
        try WorkspaceSignature.validated(
            width: 100,
            height: 80,
            pixelFormat: .bgra8Unorm,
            configuration: .init(iterations: 3, offset: .nan)
        )
    }
}

private enum RealtimeScenario: CaseIterable {
    case noFrame, noDrawable, poolExhausted, encodeThrows, commandFailure, normal
}

private final class FakeDrawable {}
