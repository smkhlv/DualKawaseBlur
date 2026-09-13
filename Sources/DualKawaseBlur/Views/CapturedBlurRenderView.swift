import Metal
import QuartzCore
import UIKit

/// UIKit render surface backing `CapturedBlurView`.
@MainActor
public final class CapturedBlurRenderView: UIView {
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    struct FrameResource: @unchecked Sendable {
        // Access to the surface and workspace is serialized by the owning frame-pool lease.
        let surface: SharedIOSurfaceTexture
        let pyramid: TexturePyramid
    }

    private let sourceView: UIView
    private let context: MetalContext
    private let renderer: DualKawaseBlurRenderer
    private let pool = FramePool<FrameResource>(resources: [])
    private let resourceManager: CapturedResourceManager
    private var driver: CapturedFrameDriver<FrameResource, CAMetalDrawable>!
    private var displayLink: CADisplayLink?
    private lazy var displayLifecycle = RealtimeDisplayLifecycle(
        setRunning: { [weak self] running in
            if running { self?.startDisplayLink() } else { self?.stopDisplayLink() }
        },
        discardPending: {}
    )

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public init(
        sourceView: UIView,
        configuration: BlurConfiguration = .init(),
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)? = nil
    ) throws {
        self.sourceView = sourceView
        context = try MetalContext()
        renderer = try DualKawaseBlurRenderer(context: context)
        resourceManager = CapturedResourceManager(
            context: context,
            pool: pool,
            configuration: configuration
        )
        super.init(frame: .zero)

        backgroundColor = .clear
        isOpaque = false
        metalLayer.device = context.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.allowsNextDrawableTimeout = true

        driver = CapturedFrameDriver(
            pool: pool,
            capture: { [sourceView, resourceManager] resource in
                resource.surface.renderView(sourceView, scale: resourceManager.scale)
            },
            nextDrawable: { [weak metalLayer] in metalLayer?.nextDrawable() },
            submit: { [context, renderer, resourceManager] resource, drawable, completion in
                guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                    throw DualKawaseBlurError.commandBufferCreationFailed
                }
                try renderer.encode(
                    source: resource.surface.texture,
                    destination: drawable.texture,
                    workspace: resource.pyramid,
                    configuration: resourceManager.configuration,
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
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
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
        resourceManager.update(configuration: configuration)
    }

    func teardown() {
        displayLifecycle.detach()
    }

    @objc private func displayLinkFired() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard width > 0, height > 0 else { return }
        do {
            try resourceManager.prepare(width: width, height: height, scale: scale)
            driver.tick()
        } catch let error as DualKawaseBlurError {
            driver.report(error)
        } catch {
            driver.report(.textureAllocationFailed)
        }
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

private struct CapturedResourceSignature: Equatable {
    let width: Int
    let height: Int
    let iterations: Int
}

@MainActor
private final class CapturedResourceManager {
    private let context: MetalContext
    private let pool: FramePool<CapturedBlurRenderView.FrameResource>
    private var signature: CapturedResourceSignature?
    private(set) var configuration: BlurConfiguration
    private(set) var scale: CGFloat = 1

    init(
        context: MetalContext,
        pool: FramePool<CapturedBlurRenderView.FrameResource>,
        configuration: BlurConfiguration
    ) {
        self.context = context
        self.pool = pool
        self.configuration = configuration
    }

    func update(configuration: BlurConfiguration) {
        self.configuration = configuration
    }

    func prepare(width: Int, height: Int, scale: CGFloat) throws {
        do {
            try configuration.validate(forWidth: width, height: height)
        } catch {
            throw DualKawaseBlurError.invalidConfiguration
        }
        self.scale = scale
        let next = CapturedResourceSignature(
            width: width,
            height: height,
            iterations: configuration.iterations
        )
        guard next != signature else { return }

        let resources = try (0..<3).map { _ in
            CapturedBlurRenderView.FrameResource(
                surface: try SharedIOSurfaceTexture(
                    device: context.device,
                    width: width,
                    height: height
                ),
                pyramid: try TexturePyramid(
                    device: context.device,
                    width: width,
                    height: height,
                    pixelFormat: .bgra8Unorm,
                    configuration: configuration
                )
            )
        }
        pool.replace(with: resources)
        signature = next
    }
}
