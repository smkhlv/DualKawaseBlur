import UIKit
import Metal
import QuartzCore

/// A container view that displays blurred content with an optional overlay.
///
/// Use this view to create real-time blur effects over dynamic content.
/// The source view is rendered to a texture, blurred using the Dual Kawase algorithm,
/// and displayed with the overlay on top.
///
/// Example:
/// ```swift
/// let container = BlurContainerView()
/// container.iterations = 3
/// container.offset = 2.0
/// container.sourceView = animatedBackgroundView
/// container.overlayView = labelView
/// ```
public final class BlurContainerView: UIView {

    // MARK: - Public Properties

    /// Number of blur iterations (1-5). Higher values produce stronger blur.
    public var iterations: Int = 3 {
        didSet {
            iterations = max(1, min(5, iterations))
            invalidatePyramid()
        }
    }

    /// Blur offset multiplier (1.0-5.0). Higher values produce wider blur.
    public var offset: Float = 2.0 {
        didSet {
            offset = max(1.0, min(5.0, offset))
        }
    }

    /// The view whose content will be blurred and displayed.
    /// Setting this property adds the view as a subview and starts the render loop.
    public var sourceView: UIView? {
        didSet {
            configureSourceView(oldValue: oldValue)
        }
    }

    /// Optional view displayed on top of the blurred content.
    public var overlayView: UIView? {
        didSet {
            configureOverlayView(oldValue: oldValue)
        }
    }

    /// Optional closure that provides a Metal texture directly each frame.
    /// When set, this takes priority over `sourceView` — the texture is used
    /// as blur input with zero CPU overhead (pure GPU path).
    /// Use this for Metal-rendered content (e.g. MTKView-based animations).
    public var textureProvider: (() -> MTLTexture?)? {
        didSet {
            if textureProvider != nil, window != nil {
                startRenderLoop()
            }
        }
    }

    // MARK: - Private Properties

    private var sourceContainerView: UIView!
    private var overlayContainerView: UIView!
    private var renderTarget: CAMetalLayer!

    private var metalContext: MetalContext?
    private var blurPipeline: BlurRenderer?
    private var texturePyramid: TexturePyramid?

    private var frameUpdateLink: CADisplayLink?
    private var needsPyramidUpdate = true

    // Triple buffering
    private static let maxInflightFrames = 3
    private let inflightSemaphore = DispatchSemaphore(value: maxInflightFrames)
    private var sharedSurfaces: [SharedIOSurfaceTexture] = []
    private var currentBufferIndex = 0
    private var lastTextureSize: CGSize = .zero

    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        clipsToBounds = true

        setupViewHierarchy()
        setupMetal()
    }

    // MARK: - Setup

    private func setupViewHierarchy() {
        // Source container - holds the view to be blurred
        sourceContainerView = UIView()
        sourceContainerView.backgroundColor = .clear
        addSubview(sourceContainerView)

        // Overlay container - holds content displayed on top of blur
        overlayContainerView = UIView()
        overlayContainerView.backgroundColor = .clear
        addSubview(overlayContainerView)
    }

    private func setupMetal() {
        do {
            metalContext = try MetalContext()

            guard let context = metalContext else { return }

            blurPipeline = try BlurRenderer(
                device: context.device,
                commandQueue: context.commandQueue,
                library: context.library
            )
            texturePyramid = TexturePyramid(device: context.device)

            setupRenderTarget(device: context.device)
        } catch {
            print("BlurContainerView: Failed to initialize Metal - \(error)")
        }
    }

    private func setupRenderTarget(device: MTLDevice) {
        renderTarget = CAMetalLayer()
        renderTarget.device = device
        renderTarget.pixelFormat = .bgra8Unorm
        renderTarget.framebufferOnly = true
        renderTarget.contentsScale = UIScreen.main.scale
        renderTarget.isOpaque = false
        // Insert above sourceContainerView but below overlayContainerView
        layer.insertSublayer(renderTarget, above: sourceContainerView.layer)
    }

    // MARK: - View Configuration

    private func configureSourceView(oldValue: UIView?) {
        oldValue?.removeFromSuperview()

        guard let source = sourceView else {
            stopRenderLoop()
            return
        }

        source.translatesAutoresizingMaskIntoConstraints = false
        sourceContainerView.addSubview(source)

        NSLayoutConstraint.activate([
            source.topAnchor.constraint(equalTo: sourceContainerView.topAnchor),
            source.leadingAnchor.constraint(equalTo: sourceContainerView.leadingAnchor),
            source.trailingAnchor.constraint(equalTo: sourceContainerView.trailingAnchor),
            source.bottomAnchor.constraint(equalTo: sourceContainerView.bottomAnchor)
        ])

        invalidatePyramid()
        startRenderLoop()
    }

    private func configureOverlayView(oldValue: UIView?) {
        oldValue?.removeFromSuperview()

        guard let overlay = overlayView else { return }

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlayContainerView.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: overlayContainerView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: overlayContainerView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: overlayContainerView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: overlayContainerView.bottomAnchor)
        ])
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()

        sourceContainerView.frame = bounds
        overlayContainerView.frame = bounds
        renderTarget.frame = bounds

        let scale = renderTarget.contentsScale
        renderTarget.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )

        invalidatePyramid()
    }

    // MARK: - Render Loop

    private func startRenderLoop() {
        guard frameUpdateLink == nil, window != nil else { return }

        frameUpdateLink = CADisplayLink(target: self, selector: #selector(processFrame))
        frameUpdateLink?.add(to: .main, forMode: .common)
    }

    private func stopRenderLoop() {
        frameUpdateLink?.invalidate()
        frameUpdateLink = nil
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil && (sourceView != nil || textureProvider != nil) {
            startRenderLoop()
        } else {
            stopRenderLoop()
        }
    }

    @objc private func processFrame(_ sender: CADisplayLink) {
        guard let context = metalContext,
              let pipeline = blurPipeline,
              let pyramid = texturePyramid else {
            return
        }

        // Get source texture: textureProvider (GPU path) or sourceView (IOSurface path)
        let sourceTexture: MTLTexture

        if let provider = textureProvider, let texture = provider() {
            // Direct GPU path — zero CPU overhead
            sourceTexture = texture
        } else if let source = sourceView,
                  source.bounds.width > 0,
                  source.bounds.height > 0 {
            // IOSurface path — capture UIView via layer.render
            let scale = renderTarget.contentsScale
            let textureSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            guard textureSize.width > 0, textureSize.height > 0 else { return }

            if textureSize != lastTextureSize {
                recreateSharedSurfaces(device: context.device, size: textureSize)
                lastTextureSize = textureSize
            }
            guard !sharedSurfaces.isEmpty else { return }

            let surface = sharedSurfaces[currentBufferIndex]
            surface.renderView(source, scale: scale)
            sourceTexture = surface.texture
            currentBufferIndex = (currentBufferIndex + 1) % Self.maxInflightFrames
        } else {
            return
        }

        // Wait for an available buffer
        inflightSemaphore.wait()

        guard let drawable = renderTarget.nextDrawable() else {
            inflightSemaphore.signal()
            return
        }

        // Update pyramid if needed
        if needsPyramidUpdate {
            do {
                let size = CGSize(width: sourceTexture.width, height: sourceTexture.height)
                try pyramid.createPyramid(size: size, iterations: iterations)
                needsPyramidUpdate = false
            } catch {
                print("BlurContainerView: Failed to create pyramid - \(error)")
                inflightSemaphore.signal()
                return
            }
        }

        // Create command buffer and encode blur
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            inflightSemaphore.signal()
            return
        }
        commandBuffer.label = "Dual Kawase Blur Live"

        // Signal semaphore when GPU finishes this frame
        let semaphore = inflightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        do {
            try pipeline.encodeBlur(
                commandBuffer: commandBuffer,
                source: sourceTexture,
                pyramid: pyramid,
                iterations: iterations,
                offset: offset,
                drawable: drawable
            )

            commandBuffer.present(drawable)
            commandBuffer.commit()
        } catch {
            print("BlurContainerView: Failed to execute blur - \(error)")
        }
    }

    // MARK: - Shared Surface Management

    private func recreateSharedSurfaces(device: MTLDevice, size: CGSize) {
        sharedSurfaces.removeAll()
        currentBufferIndex = 0

        let w = Int(size.width)
        let h = Int(size.height)

        for _ in 0..<Self.maxInflightFrames {
            guard let surface = SharedIOSurfaceTexture(device: device, width: w, height: h) else {
                print("BlurContainerView: Failed to create shared surface")
                return
            }
            sharedSurfaces.append(surface)
        }
    }

    // MARK: - Invalidation

    private func invalidatePyramid() {
        needsPyramidUpdate = true
    }

    /// Forces an immediate blur update.
    public func setNeedsBlurUpdate() {
        processFrame(frameUpdateLink ?? CADisplayLink())
    }

    /// Clears cached resources. Call on memory warning.
    public func clearCache() {
        texturePyramid?.clear()
        sharedSurfaces.removeAll()
        lastTextureSize = .zero
        needsPyramidUpdate = true
    }

    // MARK: - Deinitialization

    deinit {
        stopRenderLoop()
    }
}
