import SwiftUI

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

    private let source: Source
    private let overlay: Overlay

    // MARK: - Initialization

    /// Creates a blur container with the specified parameters.
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
    }

    // MARK: - UIViewRepresentable

    public func makeUIView(context: Context) -> BlurContainerView {
        let containerView = BlurContainerView()
        containerView.iterations = iterations
        containerView.offset = offset

        // Create hosting controller for source content
        let sourceHosting = UIHostingController(rootView: source)
        sourceHosting.view.backgroundColor = .clear
        containerView.sourceView = sourceHosting.view
        context.coordinator.sourceHosting = sourceHosting

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

        // Update source content
        context.coordinator.sourceHosting?.rootView = source

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
