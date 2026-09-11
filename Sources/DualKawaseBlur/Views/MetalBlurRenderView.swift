import Metal
import QuartzCore
import UIKit

/// A managed Metal surface that displays the latest frame published by a `MetalBlurFrameSource`.
@MainActor
public final class MetalBlurRenderView: UIView {
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    fileprivate struct Workspace: @unchecked Sendable {
        // Immutable Metal resources; access is serialized by their owning command buffer lease.
        let pyramid: TexturePyramid
    }

    let source: MetalBlurFrameSource
    private let context: MetalContext
    private let renderer: DualKawaseBlurRenderer
    private let pool = FramePool<Workspace>(resources: [])
    private let workspaceManager: WorkspaceManager
    private var driver: RealtimeFrameDriver<Workspace, CAMetalDrawable>!
    private var displayLink: CADisplayLink?
    private var configuration: BlurConfiguration
    private lazy var displayLifecycle = RealtimeDisplayLifecycle(
        setRunning: { [weak self] running in
            if running { self?.startDisplayLink() } else { self?.stopDisplayLink() }
        },
        discardPending: { [weak self] in self?.driver.teardown() }
    )

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public init(
        source: MetalBlurFrameSource,
        configuration: BlurConfiguration = .init(),
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)? = nil
    ) throws {
        self.source = source
        self.configuration = configuration
        context = try MetalContext()
        renderer = try DualKawaseBlurRenderer(context: context)
        workspaceManager = WorkspaceManager(
            context: context,
            pool: pool,
            configuration: configuration
        )
        super.init(frame: .zero)

        isOpaque = false
        metalLayer.device = context.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.allowsNextDrawableTimeout = true

        driver = RealtimeFrameDriver(
            source: source,
            pool: pool,
            prepare: { [workspaceManager] frame in
                try workspaceManager.prepare(for: frame.texture)
            },
            nextDrawable: { [weak metalLayer] in metalLayer?.nextDrawable() },
            submit: { [context, renderer, workspaceManager] frame, workspace, drawable, completion in
                guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                    throw DualKawaseBlurError.commandBufferCreationFailed
                }
                if case let .sharedEvent(event, value) = frame.readiness {
                    commandBuffer.encodeWaitForEvent(event, value: value)
                }
                try renderer.encode(
                    source: frame.texture,
                    destination: drawable.texture,
                    workspace: workspace.pyramid,
                    configuration: workspaceManager.configuration,
                    into: commandBuffer
                )
                commandBuffer.addCompletedHandler { commandBuffer in
                    completion(commandBuffer.status == .completed ? nil : .gpuExecutionFailed)
                }
                commandBuffer.present(drawable)
                commandBuffer.commit()
            },
            onError: onError
        )
        observeApplicationLifecycle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLifecycle.detach()
        } else {
            displayLifecycle.attach(isApplicationActive: UIApplication.shared.applicationState == .active)
        }
    }

    func update(configuration: BlurConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        workspaceManager.update(configuration: configuration)
    }

    func teardown() {
        displayLifecycle.detach()
        driver.teardown()
    }

    func report(_ error: DualKawaseBlurError) {
        driver.report(error)
    }

    @objc private func displayLinkFired() {
        driver.tick()
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationWillResignActive() {
        displayLifecycle.willResignActive()
    }

    @objc private func applicationDidBecomeActive() {
        displayLifecycle.didBecomeActive()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

}

struct WorkspaceSignature: Equatable {
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
    let iterations: Int

    init(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        configuration: BlurConfiguration
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        iterations = configuration.iterations
    }

    static func validated(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        configuration: BlurConfiguration
    ) throws -> Self {
        do {
            try configuration.validate(forWidth: width, height: height)
        } catch {
            throw DualKawaseBlurError.invalidConfiguration
        }
        return Self(
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            configuration: configuration
        )
    }
}

@MainActor
private final class WorkspaceManager {
    private let context: MetalContext
    private let pool: FramePool<MetalBlurRenderView.Workspace>
    private var signature: WorkspaceSignature?
    private(set) var configuration: BlurConfiguration

    init(
        context: MetalContext,
        pool: FramePool<MetalBlurRenderView.Workspace>,
        configuration: BlurConfiguration
    ) {
        self.context = context
        self.pool = pool
        self.configuration = configuration
    }

    func update(configuration: BlurConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
    }

    func prepare(for texture: MTLTexture) throws {
        let next = try WorkspaceSignature.validated(
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat,
            configuration: configuration
        )
        guard next != signature else { return }
        let resources = try (0..<3).map { _ in
            MetalBlurRenderView.Workspace(pyramid: try TexturePyramid(
                device: context.device,
                width: texture.width,
                height: texture.height,
                pixelFormat: texture.pixelFormat,
                configuration: configuration
            ))
        }
        pool.replace(with: resources)
        signature = next
    }
}
