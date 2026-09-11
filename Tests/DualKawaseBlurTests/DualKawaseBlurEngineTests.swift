import Metal
import Testing
import UIKit
@testable import DualKawaseBlur

@MainActor
@Test func blurPreservesScaleAndVisualOrientation() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let source = TestImage.asymmetricUIImage(scale: 3, orientation: .right)
    let engine = try DualKawaseBlurEngine()

    let result = try await engine.blur(
        source,
        configuration: .init(iterations: 1, offset: 1)
    )

    #expect(result.scale == 3)
    #expect(result.imageOrientation == .up)
    #expect(result.size == source.size)
}

@MainActor
@Test func cancelledBlurReturnsCancellationError() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try DualKawaseBlurEngine()
    let image = TestImage.largeUIImage()
    let task = Task {
        try await engine.blur(image, configuration: .init(iterations: 4, offset: 2))
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

@MainActor
@Test func blurRejectsInvalidConfiguration() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try DualKawaseBlurEngine()
    let image = TestImage.asymmetricUIImage(scale: 1, orientation: .up)

    await #expect(throws: DualKawaseBlurError.invalidConfiguration) {
        try await engine.blur(image, configuration: .init(iterations: 0, offset: 1))
    }
}

@MainActor
@Test func blurMapsInvalidImageToPublicError() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try DualKawaseBlurEngine()

    await #expect(throws: DualKawaseBlurError.unsupportedTexture) {
        try await engine.blur(UIImage(), configuration: .init(iterations: 1, offset: 1))
    }
}

@Test func lowLevelEncodeLeavesCallerCommandBufferUncommitted() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let engine = try DualKawaseBlurEngine(device: device)
    let source = try TestTexture.impulse(device: device, width: 16, height: 16)
    let destination = try TestTexture.empty(device: device, width: 16, height: 16)
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())

    try engine.encode(
        source: source,
        destination: destination,
        configuration: .init(iterations: 2, offset: 1),
        into: commandBuffer
    )

    #expect(commandBuffer.status == .notEnqueued)
}

@Test func lowLevelEncodeSupportsCommandBuffersWithUnretainedReferences() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let engine = try DualKawaseBlurEngine(device: device)
    let source = try TestTexture.impulse(device: device, width: 16, height: 16)
    let destination = try TestTexture.empty(device: device, width: 16, height: 16)
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBufferWithUnretainedReferences())

    try engine.encode(source: source, destination: destination, configuration: .init(iterations: 2, offset: 1), into: commandBuffer)
    #expect(commandBuffer.status == .notEnqueued)
    #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
    #expect(try TestTexture.nonZeroPixelCount(destination) > 1)
}

@Test func lowLevelEncodeRejectsAlreadyCommittedCommandBuffer() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let engine = try DualKawaseBlurEngine(device: device)
    let source = try TestTexture.impulse(device: device, width: 16, height: 16)
    let destination = try TestTexture.empty(device: device, width: 16, height: 16)
    let queue = try #require(device.makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())
    #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)

    #expect(throws: DualKawaseBlurError.unsupportedTexture) {
        try engine.encode(
            source: source,
            destination: destination,
            configuration: .init(iterations: 2, offset: 1),
            into: commandBuffer
        )
    }
}

@Test func lowLevelEncodeRejectsForeignDevice() throws {
    let devices = MTLCopyAllDevices()
    guard devices.count > 1 else { return }
    let engine = try DualKawaseBlurEngine(device: devices[0])
    let source = try TestTexture.impulse(device: devices[1], width: 8, height: 8)
    let destination = try TestTexture.empty(device: devices[1], width: 8, height: 8)
    let queue = try #require(devices[1].makeCommandQueue())
    let commandBuffer = try #require(queue.makeCommandBuffer())

    #expect(throws: DualKawaseBlurError.unsupportedTexture) {
        try engine.encode(
            source: source,
            destination: destination,
            configuration: .init(iterations: 1, offset: 1),
            into: commandBuffer
        )
    }
}

@Test func stillImageSchedulerRemovesCancelledQueuedOperationBeforeItStarts() async throws {
    let scheduler = StillImageScheduler(capacity: 1)
    let gate = OneShotGate()
    let (started, events) = AsyncStream.makeStream(of: Int.self)
    var iterator = started.makeAsyncIterator()
    let first = Task {
        try await scheduler.schedule {
            events.yield(1)
            await gate.wait()
            return 1
        }
    }
    #expect(await iterator.next() == 1)

    let second = Task {
        try await scheduler.schedule {
            events.yield(2)
            return 2
        }
    }
    #expect(await waitForInspection(scheduler) { $0.queued == 1 })
    second.cancel()
    await #expect(throws: CancellationError.self) { try await second.value }
    await gate.open()
    #expect(try await first.value == 1)
    events.finish()
    #expect(await iterator.next() == nil)
    #expect(await scheduler.inspection() == .empty)
}

@Test func stillImageSchedulerReleasesCapacityAfterActiveCancellation() async throws {
    let scheduler = StillImageScheduler(capacity: 1)
    let gate = OneShotGate()
    let (started, events) = AsyncStream.makeStream(of: Void.self)
    var iterator = started.makeAsyncIterator()
    let cancelled = Task {
        try await scheduler.schedule {
            events.yield()
            await gate.wait()
            return 1
        }
    }
    _ = await iterator.next()
    cancelled.cancel()
    await gate.open()
    await #expect(throws: CancellationError.self) { try await cancelled.value }

    #expect(try await scheduler.schedule { 2 } == 2)
    #expect(await scheduler.inspection() == .empty)
}

@Test func stillImageSchedulerCleansUpCancellationAfterPromotion() async throws {
    let scheduler = StillImageScheduler(capacity: 1)
    let firstGate = OneShotGate()
    let promotedGate = OneShotGate()
    let (started, events) = AsyncStream.makeStream(of: Int.self)
    var iterator = started.makeAsyncIterator()
    let first = Task {
        try await scheduler.schedule {
            events.yield(1)
            await firstGate.wait()
            return 1
        }
    }
    #expect(await iterator.next() == 1)
    let promoted = Task {
        try await scheduler.schedule {
            events.yield(2)
            await promotedGate.wait()
            return 2
        }
    }
    #expect(await waitForInspection(scheduler) { $0.queued == 1 })

    await firstGate.open()
    #expect(try await first.value == 1)
    #expect(await iterator.next() == 2)
    promoted.cancel()
    await promotedGate.open()
    await #expect(throws: CancellationError.self) { try await promoted.value }

    #expect(try await scheduler.schedule { 3 } == 3)
    #expect(await scheduler.inspection() == .empty)
}

@Test func stillImageSchedulerHonorsCapacityWithConcurrentScheduling() async throws {
    let scheduler = StillImageScheduler(capacity: 2)
    let firstGate = OneShotGate()
    let secondGate = OneShotGate()
    let (started, events) = AsyncStream.makeStream(of: Int.self)
    var iterator = started.makeAsyncIterator()
    let first = Task {
        try await scheduler.schedule {
            events.yield(1)
            await firstGate.wait()
            return 1
        }
    }
    let second = Task {
        try await scheduler.schedule {
            events.yield(2)
            await secondGate.wait()
            return 2
        }
    }
    _ = await iterator.next()
    _ = await iterator.next()

    let third = Task { try await scheduler.schedule { 3 } }
    #expect(await waitForInspection(scheduler) { $0.active == 2 && $0.queued == 1 })
    await firstGate.open()
    #expect(try await first.value == 1)
    #expect(try await third.value == 3)
    await secondGate.open()
    #expect(try await second.value == 2)
    #expect(await scheduler.inspection() == .empty)
}

@Test func stillImageSchedulerIgnoresCancellationAfterSuccessfulCompletion() async throws {
    let scheduler = StillImageScheduler(capacity: 1)
    let completed = Task { try await scheduler.schedule { 42 } }
    #expect(try await completed.value == 42)

    completed.cancel()
    for _ in 0..<20 { await Task.yield() }

    #expect(await scheduler.inspection() == .empty)
    #expect(try await scheduler.schedule { 43 } == 43)
}

@Test func stillImageSchedulerDoesNotRetainLateImmediateCancellationMarkers() async throws {
    let scheduler = StillImageScheduler(capacity: 1)
    for _ in 0..<100 {
        let arrivalGate = OneShotGate()
        let task = Task {
            await arrivalGate.wait()
            return try await scheduler.schedule { 1 }
        }
        task.cancel()
        await arrivalGate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(await scheduler.inspection() == .init(registered: 0, active: 0, queued: 0, cancellationMarkers: 0))
}

@Test(arguments: [
    (ImageTextureConverter.ConversionError.cgImageCreationFailed, DualKawaseBlurError.unsupportedTexture),
    (.invalidTextureFormat, .unsupportedTexture),
    (.textureCreationFailed, .textureAllocationFailed),
    (.bufferCreationFailed, .commandBufferCreationFailed),
])
func imageReconstructionErrorsMapToCanonicalPublicErrors(
    conversionError: ImageTextureConverter.ConversionError,
    expected: DualKawaseBlurError
) {
    #expect(DualKawaseBlurEngine.publicError(for: conversionError) == expected)
}

@MainActor
@Test func blurPreservesPartialAlpha() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try DualKawaseBlurEngine()
    let result = try await engine.blur(TestImage.partiallyTransparentUIImage(), configuration: .init(iterations: 1, offset: 1))
    let center = try resultAlpha(at: CGPoint(x: 8, y: 8), image: result)
    #expect(center > 0 && center < 255)
}

@MainActor
private func resultAlpha(at point: CGPoint, image: UIImage) throws -> UInt8 {
    let cgImage = try #require(image.cgImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.translateBy(x: -point.x, y: -point.y)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    return pixel[3]
}

private actor OneShotGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private func waitForInspection(
    _ scheduler: StillImageScheduler,
    matching predicate: (StillImageScheduler.Inspection) -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if predicate(await scheduler.inspection()) { return true }
        await Task.yield()
    }
    return false
}

private extension StillImageScheduler.Inspection {
    static let empty = Self(registered: 0, active: 0, queued: 0, cancellationMarkers: 0)
}
