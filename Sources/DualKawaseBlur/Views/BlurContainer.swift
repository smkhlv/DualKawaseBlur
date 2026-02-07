import SwiftUI
import Metal

/// A SwiftUI container that displays blurred content with an overlay.
///
/// Use this view to create real-time blur effects over dynamic SwiftUI content.
/// The source content is rendered, blurred using the Dual Kawase algorithm,
/// and displayed with the overlay on top.
///
/// Example:
/// ```swift
/// BlurContainer(iterations: 3, offset: 2.0) {
///     AnimatedGradientBackground()
/// } overlay: {
///     Text("Content on blur")
///         .font(.title)
/// }
/// ```
@available(iOS 13.0, *)
public struct BlurContainer<Source: View, Overlay: View>: UIViewRepresentable {

    // MARK: - Properties

    /// Number of blur iterations (1-5). Higher values produce stronger blur.
    public let iterations: Int

    /// Blur offset multiplier (1.0-5.0). Higher values produce wider blur.
    public let offset: Float

    private let source: Source?
    private let overlay: Overlay
    private let textureProvider: (() -> MTLTexture?)?

    // MARK: - Initialization

    /// Creates a blur container with SwiftUI source content.
    /// - Parameters:
    ///   - iterations: Number of blur iterations (1-5). Default is 3.
    ///   - offset: Blur offset multiplier (1.0-5.0). Default is 2.0.
    ///   - source: The content to be blurred.
    ///   - overlay: The content displayed on top of the blur.
    public init(
        iterations: Int = 3,
        offset: Float = 2.0,
        @ViewBuilder source: () -> Source,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.iterations = iterations
        self.offset = offset
        self.source = source()
        self.overlay = overlay()
        self.textureProvider = nil
    }

    // MARK: - UIViewRepresentable

    public func makeUIView(context: Context) -> BlurContainerView {
        let containerView = BlurContainerView()
        containerView.iterations = iterations
        containerView.offset = offset

        if let textureProvider = textureProvider {
            // Direct GPU path — no source view needed
            containerView.textureProvider = textureProvider
        } else if let source = source {
            // SwiftUI source view path
            let sourceHosting = UIHostingController(rootView: source)
            sourceHosting.view.backgroundColor = .clear
            containerView.sourceView = sourceHosting.view
            context.coordinator.sourceHosting = sourceHosting
        }

        // Create hosting controller for overlay content
        let overlayHosting = UIHostingController(rootView: overlay)
        overlayHosting.view.backgroundColor = .clear
        containerView.overlayView = overlayHosting.view
        context.coordinator.overlayHosting = overlayHosting

        return containerView
    }

    public func updateUIView(_ uiView: BlurContainerView, context: Context) {
        uiView.iterations = iterations
        uiView.offset = offset

        if textureProvider != nil {
            uiView.textureProvider = textureProvider
        } else {
            // Update source content
            if let source = source {
                context.coordinator.sourceHosting?.rootView = source
            }
        }

        // Update overlay content
        context.coordinator.overlayHosting?.rootView = overlay
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    public class Coordinator {
        var sourceHosting: UIHostingController<Source>?
        var overlayHosting: UIHostingController<Overlay>?
    }
}

// MARK: - Convenience Initializer (No Overlay)

@available(iOS 13.0, *)
public extension BlurContainer where Overlay == EmptyView {

    /// Creates a blur container without an overlay.
    /// - Parameters:
    ///   - iterations: Number of blur iterations (1-5). Default is 3.
    ///   - offset: Blur offset multiplier (1.0-5.0). Default is 2.0.
    ///   - source: The content to be blurred.
    init(
        iterations: Int = 3,
        offset: Float = 2.0,
        @ViewBuilder source: () -> Source
    ) {
        self.init(iterations: iterations, offset: offset, source: source) {
            EmptyView()
        }
    }
}

// MARK: - Metal Texture Provider Initializer

@available(iOS 13.0, *)
public extension BlurContainer where Source == EmptyView {

    /// Creates a blur container that takes a Metal texture directly each frame.
    /// Use this for Metal-rendered content (e.g. MTKView-based animations).
    /// Zero CPU overhead — pure GPU blur pipeline.
    /// - Parameters:
    ///   - iterations: Number of blur iterations (1-5). Default is 3.
    ///   - offset: Blur offset multiplier (1.0-5.0). Default is 2.0.
    ///   - textureProvider: Closure called each frame to get the source texture.
    ///   - overlay: The content displayed on top of the blur.
    init(
        iterations: Int = 3,
        offset: Float = 2.0,
        textureProvider: @escaping () -> MTLTexture?,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.iterations = iterations
        self.offset = offset
        self.source = nil
        self.overlay = overlay()
        self.textureProvider = textureProvider
    }
}

@available(iOS 13.0, *)
public extension BlurContainer where Source == EmptyView, Overlay == EmptyView {

    /// Creates a blur container that takes a Metal texture directly, without overlay.
    init(
        iterations: Int = 3,
        offset: Float = 2.0,
        textureProvider: @escaping () -> MTLTexture?
    ) {
        self.iterations = iterations
        self.offset = offset
        self.source = nil
        self.overlay = EmptyView()
        self.textureProvider = textureProvider
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 13.0, *)
struct BlurContainer_Previews: PreviewProvider {
    static var previews: some View {
        BlurContainer(iterations: 3, offset: 2.0) {
            LinearGradient(
                colors: [.blue, .purple, .pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } overlay: {
            Text("Blurred Content")
                .font(.title)
                .foregroundColor(.white)
        }
        .frame(width: 300, height: 200)
        .cornerRadius(20)
    }
}
#endif
