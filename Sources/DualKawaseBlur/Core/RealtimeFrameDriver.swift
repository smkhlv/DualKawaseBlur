import Foundation
import Synchronization

/// Synchronous ownership state machine used by display-link driven renderers.
/// All UI and Metal setup stays in the injected closures, which keeps every early return testable.
@MainActor
final class RealtimeFrameDriver<Resource: Sendable, Drawable: AnyObject> {
    typealias Completion = @Sendable (DualKawaseBlurError?) -> Void
    typealias Submit = (
        _ frame: MetalBlurFrame,
        _ resource: Resource,
        _ drawable: Drawable,
        _ completion: @escaping Completion
    ) throws -> Void

    private let source: MetalBlurFrameSource
    private let pool: FramePool<Resource>
    private let prepare: (MetalBlurFrame) throws -> Void
    private let nextDrawable: () -> Drawable?
    private let submit: Submit
    private let errorReporter: RealtimeErrorReporter
    private let completionInbox = RealtimeCompletionInbox()
    private var nextSequence: UInt64 = 0

    init(
        source: MetalBlurFrameSource,
        pool: FramePool<Resource>,
        prepare: @escaping (MetalBlurFrame) throws -> Void = { _ in },
        nextDrawable: @escaping () -> Drawable?,
        submit: @escaping Submit,
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?
    ) {
        self.source = source
        self.pool = pool
        self.prepare = prepare
        self.nextDrawable = nextDrawable
        self.submit = submit
        errorReporter = RealtimeErrorReporter(onError: onError)
    }

    /// Executes one non-blocking render attempt.
    func tick() {
        drainCompletionEvents()
        guard let frame = source.takeLatest() else {
            return
        }
        let sequence = makeSequence()
        do {
            try prepare(frame)
        } catch let error as DualKawaseBlurError {
            frame.releaseAfterConsumption()
            errorReporter.apply(sequence: sequence, error: error)
            return
        } catch {
            frame.releaseAfterConsumption()
            errorReporter.apply(sequence: sequence, error: .textureAllocationFailed)
            return
        }
        guard let consumer = pool.tryAcquire() else {
            frame.releaseAfterConsumption()
            return
        }
        guard let drawable = nextDrawable() else {
            consumer.release()
            frame.releaseAfterConsumption()
            return
        }

        let completion = RealtimeFrameCompletion(
            producer: frame,
            consumer: consumer,
            sequence: sequence,
            completionInbox: completionInbox
        )
        do {
            try submit(frame, consumer.resource, drawable) { error in
                completion.finish(error: error)
            }
        } catch let error as DualKawaseBlurError {
            completion.cancelBeforeSubmission()
            errorReporter.apply(sequence: sequence, error: error)
        } catch {
            completion.cancelBeforeSubmission()
            errorReporter.apply(sequence: sequence, error: .gpuExecutionFailed)
        }
    }

    func teardown() {
        source.discardPendingFrame()
    }

    func report(_ error: DualKawaseBlurError) {
        errorReporter.apply(sequence: makeSequence(), error: error)
    }

    private func makeSequence() -> UInt64 {
        nextSequence &+= 1
        return nextSequence
    }

    private func drainCompletionEvents() {
        for event in completionInbox.drain().events.sorted(by: { $0.sequence < $1.sequence }) {
            errorReporter.apply(sequence: event.sequence, error: event.error)
        }
    }
}

@MainActor
final class RealtimeErrorReporter: Sendable {
    private let onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?
    private var lastError: DualKawaseBlurError?
    private var lastSequence: UInt64 = 0

    init(onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?) {
        self.onError = onError
    }

    func apply(sequence: UInt64, error: DualKawaseBlurError?) {
        guard sequence > lastSequence else { return }
        lastSequence = sequence
        guard let error else {
            lastError = nil
            return
        }
        guard error != lastError else { return }
        lastError = error
        onError?(error)
    }
}

struct RealtimeCompletionEvent: Sendable {
    let sequence: UInt64
    let error: DualKawaseBlurError?
}

struct RealtimeCompletionBatch: Sendable {
    let first: RealtimeCompletionEvent?
    let second: RealtimeCompletionEvent?
    let third: RealtimeCompletionEvent?

    var events: [RealtimeCompletionEvent] {
        [first, second, third].compactMap { $0 }
    }
}

final class RealtimeCompletionInbox: Sendable {
    private struct Storage: Sendable {
        var first: RealtimeCompletionEvent?
        var second: RealtimeCompletionEvent?
        var third: RealtimeCompletionEvent?
        var nextIndex = 0
    }

    private let storage = Mutex(Storage())

    func record(sequence: UInt64, error: DualKawaseBlurError?) {
        let event = RealtimeCompletionEvent(sequence: sequence, error: error)
        storage.withLock { storage in
            switch storage.nextIndex {
            case 0: storage.first = event
            case 1: storage.second = event
            default: storage.third = event
            }
            storage.nextIndex = (storage.nextIndex + 1) % 3
        }
    }

    func drain() -> RealtimeCompletionBatch {
        storage.withLock { storage in
            let batch = RealtimeCompletionBatch(
                first: storage.first,
                second: storage.second,
                third: storage.third
            )
            storage.first = nil
            storage.second = nil
            storage.third = nil
            storage.nextIndex = 0
            return batch
        }
    }
}

private final class RealtimeFrameCompletion<Resource: Sendable>: Sendable {
    private struct State {
        var producer: MetalBlurFrame?
        var consumer: FramePool<Resource>.Lease?
    }

    private let state: Mutex<State>
    private let sequence: UInt64
    private let completionInbox: RealtimeCompletionInbox

    init(
        producer: MetalBlurFrame,
        consumer: FramePool<Resource>.Lease,
        sequence: UInt64,
        completionInbox: RealtimeCompletionInbox
    ) {
        state = Mutex(State(producer: producer, consumer: consumer))
        self.sequence = sequence
        self.completionInbox = completionInbox
    }

    func finish(error: DualKawaseBlurError?) {
        releaseLeases()
        completionInbox.record(sequence: sequence, error: error)
    }

    func cancelBeforeSubmission() {
        releaseLeases()
    }

    private func releaseLeases() {
        let leases = state.withLock { state -> State in
            defer {
                state.producer = nil
                state.consumer = nil
            }
            return state
        }
        leases.consumer?.release()
        leases.producer?.releaseAfterConsumption()
    }
}

/// Testable application/window lifecycle policy for the display-link hot path.
@MainActor
final class RealtimeDisplayLifecycle {
    private let setRunning: (Bool) -> Void
    private let discardPending: () -> Void
    private var isAttached = false
    private var isActive = false
    private var isRunning = false

    init(setRunning: @escaping (Bool) -> Void, discardPending: @escaping () -> Void) {
        self.setRunning = setRunning
        self.discardPending = discardPending
    }

    func attach(isApplicationActive: Bool) {
        isAttached = true
        isActive = isApplicationActive
        if isActive { discardPending() }
        reconcile()
    }

    func detach() {
        guard isAttached else { return }
        isAttached = false
        reconcile()
        discardPending()
    }

    func willResignActive() {
        guard isActive else { return }
        isActive = false
        reconcile()
        discardPending()
    }

    func didBecomeActive() {
        isActive = true
        if isAttached { discardPending() }
        reconcile()
    }

    private func reconcile() {
        let shouldRun = isAttached && isActive
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        setRunning(shouldRun)
    }
}
