import Synchronization

/// Testable ownership state machine for the CPU-captured real-time path.
/// The pool lease is acquired before capture begins and remains alive until GPU completion.
@MainActor
final class CapturedFrameDriver<Resource: Sendable, Drawable: AnyObject> {
    typealias Completion = @Sendable (DualKawaseBlurError?) -> Void
    typealias Submit = (
        _ resource: Resource,
        _ drawable: Drawable,
        _ completion: @escaping Completion
    ) throws -> Void

    private let pool: FramePool<Resource>
    private let capture: (Resource) throws -> Void
    private let nextDrawable: () -> Drawable?
    private let submit: Submit
    private let errorReporter: RealtimeErrorReporter
    private let completionInbox = RealtimeCompletionInbox()
    private var nextSequence: UInt64 = 0

    init(
        pool: FramePool<Resource>,
        capture: @escaping (Resource) throws -> Void,
        nextDrawable: @escaping () -> Drawable?,
        submit: @escaping Submit,
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?
    ) {
        self.pool = pool
        self.capture = capture
        self.nextDrawable = nextDrawable
        self.submit = submit
        errorReporter = RealtimeErrorReporter(onError: onError)
    }

    func tick() {
        drainCompletionEvents()
        let sequence = makeSequence()
        guard let lease = pool.tryAcquire() else { return }

        do {
            try capture(lease.resource)
        } catch let error as DualKawaseBlurError {
            lease.release()
            errorReporter.apply(sequence: sequence, error: error)
            return
        } catch {
            lease.release()
            errorReporter.apply(sequence: sequence, error: .textureAllocationFailed)
            return
        }

        guard let drawable = nextDrawable() else {
            lease.release()
            return
        }

        let completion = CapturedFrameCompletion(
            lease: lease,
            sequence: sequence,
            completionInbox: completionInbox
        )
        do {
            try submit(lease.resource, drawable) { error in
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

private final class CapturedFrameCompletion<Resource: Sendable>: Sendable {
    private let lease: Mutex<FramePool<Resource>.Lease?>
    private let sequence: UInt64
    private let completionInbox: RealtimeCompletionInbox

    init(
        lease: FramePool<Resource>.Lease,
        sequence: UInt64,
        completionInbox: RealtimeCompletionInbox
    ) {
        self.lease = Mutex(lease)
        self.sequence = sequence
        self.completionInbox = completionInbox
    }

    func finish(error: DualKawaseBlurError?) {
        takeLease()?.release()
        completionInbox.record(sequence: sequence, error: error)
    }

    func cancelBeforeSubmission() {
        takeLease()?.release()
    }

    private func takeLease() -> FramePool<Resource>.Lease? {
        lease.withLock { lease in
            defer { lease = nil }
            return lease
        }
    }
}
