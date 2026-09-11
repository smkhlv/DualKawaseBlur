import Synchronization

/// A single-consumer, latest-frame mailbox for animated Metal producers.
///
/// The source keeps at most one frame. Publishing replaces and releases stale work so a
/// slow consumer cannot create an unbounded frame backlog.
public final class MetalBlurFrameSource: Sendable {
    private struct State {
        var latest: MetalBlurFrame?
        var isFinished = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Publishes the newest frame, releasing any older unconsumed frame.
    public func publish(_ frame: MetalBlurFrame) {
        guard frame.beginPublication() else {
            return
        }

        let frameToRelease = state.withLock { state -> MetalBlurFrame? in
            guard !state.isFinished else {
                return frame
            }

            let displacedFrame = state.latest
            state.latest = frame
            return displacedFrame
        }

        frameToRelease?.releaseAfterConsumption()
    }

    /// Finishes delivery, releasing a pending frame and immediately rejecting future work.
    public func finish() {
        let frameToRelease = state.withLock { state -> MetalBlurFrame? in
            guard !state.isFinished else {
                return nil
            }

            state.isFinished = true
            let pendingFrame = state.latest
            state.latest = nil
            return pendingFrame
        }

        frameToRelease?.releaseAfterConsumption()
    }

    /// Atomically transfers the latest frame to the single consumer.
    func takeLatest() -> MetalBlurFrame? {
        let frame = state.withLock { state in
            let frame = state.latest
            state.latest = nil
            return frame
        }

        guard let frame, frame.beginConsumption() else {
            return nil
        }
        return frame
    }

    /// Drops the pending frame without closing the source to future publications.
    func discardPendingFrame() {
        let frameToRelease = state.withLock { state -> MetalBlurFrame? in
            let pendingFrame = state.latest
            state.latest = nil
            return pendingFrame
        }

        frameToRelease?.releaseAfterConsumption()
    }
}
