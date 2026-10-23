import Foundation
import Metal
import Synchronization
import Testing
@testable import DualKawaseBlur

@Test @MainActor func renderLatestDoesNotEncodeOnCallingThread() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let schedule = RecordingSchedule()
    let session = try SharedMetalBlurSession(
        source: source,
        configuration: .init(),
        device: device,
        schedule: schedule.schedule
    )
    defer { session.finish() }
    let consumed = Mutex(0)
    let texture = try TestTexture.impulse(device: device, width: 32, height: 32)
    source.publish(MetalBlurFrame(texture: texture) { consumed.withLock { $0 += 1 } })

    session.renderLatest()

    #expect(schedule.count == 1)
    #expect(consumed.withLock { $0 } == 0)
    #expect(session.latestCompletedFrameInfo == nil)

    schedule.runAll()
    var info: SharedMetalBlurFrameInfo?
    for _ in 0..<300 where info?.pixelWidth != 32 {
        info = session.latestCompletedFrameInfo
        if info?.pixelWidth != 32 { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    #expect(info?.pixelWidth == 32)
}

@Test @MainActor func renderRequestsCoalesceWhileJobPending() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let schedule = RecordingSchedule()
    let session = try SharedMetalBlurSession(
        source: MetalBlurFrameSource(),
        configuration: .init(),
        device: device,
        schedule: schedule.schedule
    )
    defer { session.finish() }

    session.renderLatest()
    session.renderLatest()
    session.renderLatest()
    #expect(schedule.count == 1)

    schedule.runAll()
    session.renderLatest()
    #expect(schedule.count == 1)
}

@Test @MainActor func finishBeforeQueuedJobPublishesNothing() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let schedule = RecordingSchedule()
    let session = try SharedMetalBlurSession(
        source: source,
        configuration: .init(),
        device: device,
        schedule: schedule.schedule
    )
    let consumed = Mutex(0)
    let texture = try TestTexture.impulse(device: device, width: 32, height: 32)
    source.publish(MetalBlurFrame(texture: texture) { consumed.withLock { $0 += 1 } })

    session.renderLatest()
    session.finish()
    schedule.runAll()

    #expect(consumed.withLock { $0 } == 1)
    #expect(session.acquireLatestOutput() == nil)
}

@Test func workerPinsRevisionBeforeTakingFrame() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let context = try MetalContext(device: device)
    let source = MetalBlurFrameSource()
    let outputs = SharedOutputFrames<SharedBlurWorkspace>(resources: [])
    let worker = SharedBlurEncodeWorker(
        source: source,
        context: context,
        outputs: outputs,
        configuration: .init(),
        schedule: { _ in },
        onPublished: {},
        onDiagnostic: { _ in }
    )
    let consumed = Mutex(0)
    let texture = try TestTexture.impulse(device: device, width: 32, height: 32)
    source.publish(MetalBlurFrame(texture: texture) { consumed.withLock { $0 += 1 } })

    let pinned = outputs.targetRevision
    let frame = try #require(source.takeLatest())
    outputs.advanceTargetRevision()
    worker.encode(frame, pinnedRevision: pinned)

    // The completion handler releases the frame before it completes the writer; a free
    // writer slot is the signal that completion ran and declined to publish.
    for _ in 0..<300 where outputs.availableWriterCount != 3 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(outputs.availableWriterCount == 3)
    #expect(consumed.withLock { $0 } == 1)
    #expect(outputs.acquireLatest() == nil)
}

@Test @MainActor func defaultScheduleRunsOffMainThread() async {
    let schedule = SharedBlurEncodeWorker.makeDefaultSchedule()
    let recorded = Mutex<Bool?>(nil)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        schedule {
            recorded.withLock { $0 = Thread.isMainThread }
            continuation.resume()
        }
    }

    #expect(recorded.withLock { $0 } == false)
}

/// Holds scheduled encode jobs until the test runs them on its own thread.
private final class RecordingSchedule: Sendable {
    private let jobs = Mutex<[@Sendable () -> Void]>([])

    var count: Int { jobs.withLock { $0.count } }

    var schedule: SharedBlurEncodeWorker.Schedule {
        { job in self.jobs.withLock { $0.append(job) } }
    }

    func runAll() {
        let pending = jobs.withLock { jobs -> [@Sendable () -> Void] in
            let pending = jobs
            jobs.removeAll()
            return pending
        }
        for job in pending { job() }
    }
}
