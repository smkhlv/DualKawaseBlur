import Metal
import Synchronization

/// Describes when an animated producer's texture is safe for the consumer GPU to sample.
public enum MetalFrameReadiness: Sendable {
    /// The producer asserts that all writes needed by the consumer are already complete.
    case ready

    /// The consumer must encode a GPU-side wait for `value` before sampling the texture.
    case sharedEvent(MTLSharedEvent, value: UInt64)
}

/// A texture from an animated Metal producer, paired with readiness and lifetime ownership.
///
/// Copies share the same internal lease. The producer's `onConsumed` callback runs exactly
/// once, after consumption or when an unconsumed frame is discarded.
public struct MetalBlurFrame: Sendable {
    private let textureReference: MetalTextureReference
    private let lifecycle: MetalBlurFrameLifecycle

    public let readiness: MetalFrameReadiness

    public var texture: MTLTexture {
        textureReference.value
    }

    public init(
        texture: MTLTexture,
        readiness: MetalFrameReadiness = .ready,
        onConsumed: @escaping @Sendable () -> Void = {}
    ) {
        textureReference = MetalTextureReference(texture)
        self.readiness = readiness
        lifecycle = MetalBlurFrameLifecycle(lease: FrameLease(onConsumed))
    }

    /// Releases the producer lease after the frame is consumed or discarded.
    func releaseAfterConsumption() {
        lifecycle.release()
    }

    func beginPublication() -> Bool {
        lifecycle.beginPublication()
    }

    func beginConsumption() -> Bool {
        lifecycle.beginConsumption()
    }
}

/// Reference-semantic lifecycle shared by every copy of one logical frame.
/// State transitions never invoke producer code while the mutex is held.
private final class MetalBlurFrameLifecycle: Sendable {
    private enum State: Sendable {
        case unpublished
        case pending
        case inFlight
        case released
    }

    private let state = Mutex(State.unpublished)
    private let lease: FrameLease

    init(lease: FrameLease) {
        self.lease = lease
    }

    func beginPublication() -> Bool {
        state.withLock { state in
            guard state == .unpublished else {
                return false
            }

            state = .pending
            return true
        }
    }

    func beginConsumption() -> Bool {
        state.withLock { state in
            guard state == .pending else {
                return false
            }

            state = .inFlight
            return true
        }
    }

    func release() {
        let shouldRelease = state.withLock { state in
            guard state != .released else {
                return false
            }

            state = .released
            return true
        }

        if shouldRelease {
            lease.release()
        }
    }
}

/// `MTLTexture` is an imported Metal resource handle whose protocol does not declare
/// `Sendable`. This wrapper is the narrow audited boundary; consumers only receive the
/// immutable handle and must obey `MetalBlurFrame`'s readiness and lease protocol.
private struct MetalTextureReference: @unchecked Sendable {
    let value: MTLTexture

    init(_ value: MTLTexture) {
        self.value = value
    }
}
