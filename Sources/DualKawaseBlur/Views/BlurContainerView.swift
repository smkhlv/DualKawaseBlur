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

    // MARK: - Private Properties

    private var sourceContainerView: UIView!
    private var overlayContainerView: UIView!
    private var renderTarget: CAMetalLayer!

    private var metalContext: MetalContext?
    private var blurPipeline: BlurRenderer?
    private var texturePyramid: TexturePyramid?
    private var sourceTexture: MTLTexture?

    private var frameUpdateLink: CADisplayLink?
    private var needsPyramidUpdate = true

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
        // Not hidden - needs to render for animations to work
        // Will be covered by the Metal layer
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

        if window != nil && sourceView != nil {
            startRenderLoop()
        } else {
            stopRenderLoop()
        }
    }

    @objc private func processFrame(_ sender: CADisplayLink) {
        guard let source = sourceView,
              source.bounds.width > 0,
              source.bounds.height > 0 else {
            return
        }

        captureSourceToTexture()
        executeBlurPass()
    }

    // MARK: - Rendering

    private func captureSourceToTexture() {
        guard let context = metalContext,
              let source = sourceView else { return }

        let scale = renderTarget.contentsScale
        let textureSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )

        guard textureSize.width > 0, textureSize.height > 0 else { return }

        // Create or recreate texture if needed
        if sourceTexture == nil ||
           sourceTexture!.width != Int(textureSize.width) ||
           sourceTexture!.height != Int(textureSize.height) {
            sourceTexture = createSourceTexture(size: textureSize, device: context.device)
        }

        guard let texture = sourceTexture else { return }

        // Use UIGraphicsImageRenderer to capture with animations
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let capturedImage = renderer.image { _ in
            // drawHierarchy captures the presentation layer (with animations!)
            source.drawHierarchy(in: source.bounds, afterScreenUpdates: false)
        }

        guard let cgImage = capturedImage.cgImage else { return }

        // Convert to BGRA pixel data for Metal texture
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * Int(textureSize.width)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgContext = CGContext(
                  data: nil,
                  width: Int(textureSize.width),
                  height: Int(textureSize.height),
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return
        }

        cgContext.draw(cgImage, in: CGRect(origin: .zero, size: textureSize))

        guard let data = cgContext.data else { return }

        let region = MTLRegionMake2D(0, 0, Int(textureSize.width), Int(textureSize.height))
        texture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
    }

    private func executeBlurPass() {
        guard let context = metalContext,
              let pipeline = blurPipeline,
              let pyramid = texturePyramid,
              let source = sourceTexture,
              let drawable = renderTarget.nextDrawable() else {
            return
        }

        // Update pyramid if needed
        if needsPyramidUpdate {
            do {
                let size = CGSize(width: source.width, height: source.height)
                try pyramid.createPyramid(size: size, iterations: iterations)
                needsPyramidUpdate = false
            } catch {
                print("BlurContainerView: Failed to create pyramid - \(error)")
                return
            }
        }

        // Execute blur and present
        do {
            try pipeline.executeBlurAsync(
                source: source,
                pyramid: pyramid,
                iterations: iterations,
                offset: offset,
                drawable: drawable
            )
        } catch {
            print("BlurContainerView: Failed to execute blur - \(error)")
        }
    }

    // MARK: - Texture Creation

    private func createSourceTexture(size: CGSize, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        return device.makeTexture(descriptor: descriptor)
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
        sourceTexture = nil
        needsPyramidUpdate = true
    }

    // MARK: - Deinitialization

    deinit {
        stopRenderLoop()
    }
}
