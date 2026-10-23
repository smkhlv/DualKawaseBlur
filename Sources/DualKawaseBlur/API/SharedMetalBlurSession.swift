import Metal
import Synchronization

/// Identifies the latest GPU-completed blur output without exposing its texture or lease.
public struct SharedMetalBlurFrameInfo: Sendable, Equatable {
    public let sequence: UInt64
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(sequence: UInt64, pixelWidth: Int, pixelHeight: Int) {
        self.sequence = sequence
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One offscreen blur producer whose completed output can be read independently by many surfaces.
@MainActor
public final class SharedMetalBlurSession {
    public let device: MTLDevice

    private let source: MetalBlurFrameSource
    private let context: MetalContext
    private let renderer: DualKawaseBlurRenderer
    private let outputs: SharedOutputFrames<SharedBlurWorkspace>
    private let worker: SharedBlurEncodeWorker
    private let notificationGate: CompletionNotificationGate
    private var presenters: [UUID: @MainActor () -> Void] = [:]
    private var onDiagnostic: (@MainActor @Sendable (String) -> Void)?
    private var presentationActivityHandler: (@MainActor @Sendable (Bool) -> Void)?

    /// Creates a session with a device compatible with every source and presenter texture.
    ///
    /// The split blur needs at least 2 pyramid levels (`configuration.iterations >= 2`) and `.bgra8Unorm`
    /// source textures. Otherwise frames are dropped, and a "workspace error" diagnostic reaches the
    /// DEBUG diagnostic handler.
    public convenience init(
        source: MetalBlurFrameSource,
        configuration: BlurConfiguration = .init(),
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        try self.init(
            source: source,
            configuration: configuration,
            device: device,
            schedule: SharedBlurEncodeWorker.makeDefaultSchedule()
        )
    }

    /// Runs encode jobs through `schedule`; tests inject one that runs on demand.
    init(
        source: MetalBlurFrameSource,
        configuration: BlurConfiguration,
        device: MTLDevice?,
        schedule: @escaping SharedBlurEncodeWorker.Schedule
    ) throws {
        let context = try MetalContext(device: device)
        let renderer = try DualKawaseBlurRenderer(context: context)
        let outputs = SharedOutputFrames<SharedBlurWorkspace>(resources: [])
        let notificationGate = CompletionNotificationGate()
        // The worker's callbacks outlive init but cannot capture `self` before it exists.
        let relay = SessionRelay()
        self.source = source
        self.device = context.device
        self.context = context
        self.renderer = renderer
        self.outputs = outputs
        self.notificationGate = notificationGate
        worker = SharedBlurEncodeWorker(
            source: source,
            context: context,
            outputs: outputs,
            configuration: configuration,
            schedule: schedule,
            onPublished: {
                let shouldSchedule = notificationGate.value.withLock { pending -> Bool in
                    guard !pending else { return false }
                    pending = true
                    return true
                }
                guard shouldSchedule else { return }
                Task { @MainActor in relay.session?.deliverCompletedFrame() }
            },
            onDiagnostic: { message in
                Task { @MainActor in relay.session?.diagnostic(message) }
            }
        )
        relay.session = self
    }

    /// Schedules an off-main encode of at most one pending frame. This path never requests a drawable.
    public func renderLatest() {
        worker.requestRender()
    }

    /// Applies a new blur configuration while keeping the last completed output readable.
    /// The initializer limits apply (`iterations >= 2`, `.bgra8Unorm` sources); frames outside them are dropped.
    public func update(configuration: BlurConfiguration) {
        worker.update(configuration: configuration)
    }

    /// Drops the one pending source frame without closing the source.
    public func discardPendingInput() {
        source.discardPendingFrame()
    }

    /// Invalidates in-flight publications and pending input while retaining the latest output.
    public func invalidatePendingFrames() {
        // Discard before advancing: the worker pins the revision before its take, so a frame
        // taken before the discard always carries a pre-advance revision and cannot publish.
        source.discardPendingFrame()
        outputs.advanceTargetRevision()
    }

    /// A value-only snapshot of the current output. The temporary read lease never escapes.
    public var latestCompletedFrameInfo: SharedMetalBlurFrameInfo? {
        guard let latest = outputs.acquireLatest() else { return nil }
        defer { latest.release() }
        return SharedMetalBlurFrameInfo(
            sequence: latest.sequence,
            pixelWidth: latest.resource.sourceWidth,
            pixelHeight: latest.resource.sourceHeight
        )
    }

    /// Reports current visibility immediately, then only empty/nonempty presenter transitions.
    public func setPresentationActivityHandler(
        _ handler: (@MainActor @Sendable (Bool) -> Void)?
    ) {
        presentationActivityHandler = handler
        handler?(!presenters.isEmpty)
    }

    /// Rejects future rendering and drops only the store's hold on its latest completed output.
    public func finish() {
        guard !outputs.isFinished else { return }
        source.finish()
        outputs.finish()
        let hadPresenters = !presenters.isEmpty
        presenters.removeAll()
        if hadPresenters { presentationActivityHandler?(false) }
        presentationActivityHandler = nil
    }

    func registerPresenter(id: UUID, requestDraw: @escaping @MainActor () -> Void) {
        let wasEmpty = presenters.isEmpty
        presenters[id] = requestDraw
        if wasEmpty { presentationActivityHandler?(true) }
        requestDraw()
    }

    func unregisterPresenter(id: UUID) {
        let wasNonempty = !presenters.isEmpty
        presenters.removeValue(forKey: id)
        if wasNonempty && presenters.isEmpty { presentationActivityHandler?(false) }
    }

    func acquireLatestOutput() -> SharedOutputFrames<SharedBlurWorkspace>.ReadLease? {
        outputs.acquireLatest()
    }

    /// The current generation's three slot workspaces, for invariant tests.
    var workspaces: [SharedBlurWorkspace] { outputs.currentResources }

    func makePresentationCommandBuffer() -> MTLCommandBuffer? {
        context.commandQueue.makeCommandBuffer()
    }

    /// `output` is a workspace's half-resolution `published` level; the composite samples it by normalized UV.
    func encodePresentation(
        output: MTLTexture,
        destination: MTLTexture,
        baseColor: SIMD4<Float>,
        mapping: SharedBackgroundUVMapping,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        try renderer.encodeOpaqueComposite(
            source: output,
            destination: destination,
            baseColor: baseColor,
            mapping: mapping,
            into: commandBuffer
        )
    }

    #if DEBUG
    /// Installs a low-frequency diagnostic callback for the debug harness.
    public func setDiagnosticHandler(_ handler: (@MainActor @Sendable (String) -> Void)?) {
        onDiagnostic = handler
    }
    #endif

    func diagnostic(_ message: String) {
        onDiagnostic?(message)
    }

    private func deliverCompletedFrame() {
        notificationGate.value.withLock { $0 = false }
        diagnostic("blur output published")
        for requestDraw in presenters.values { requestDraw() }
    }
}

private final class CompletionNotificationGate: Sendable {
    let value = Mutex(false)
}

/// Weakly points the worker's main-actor hops at the session once it finishes initializing.
@MainActor
private final class SessionRelay {
    weak var session: SharedMetalBlurSession?
}

struct SharedWorkspaceSignature: Equatable {
    let width: Int
    let height: Int
    let format: MTLPixelFormat
    let iterations: Int
    let offset: Float
}

struct SharedBlurWorkspace: @unchecked Sendable {
    // The encoder is owned by one output slot until all GPU readers retire.
    let blur: SplitRoleBlurEncoder
    /// The source size, which `SharedMetalBlurFrameInfo` reports; the published texture is half of it.
    let sourceWidth: Int
    let sourceHeight: Int

    /// The half-resolution blur result presenters composite; the slot's own pyramid level 0.
    var published: MTLTexture { blur.intermediateTextures[0] }
}
