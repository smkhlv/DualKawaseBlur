import SwiftUI
import Metal

/// A SwiftUI container that renders blurred content with an overlay.
///
/// Use `UIViewControllerRepresentable` so that SwiftUI manages the view controller
/// hierarchy correctly. This guarantees that the overlay `UIHostingController` is
/// embedded via `addChild`/`didMove(toParent:)`, which is required for `NavigationStack`,
/// `TabView`, safe area insets, and keyboard avoidance to work properly inside the overlay.
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
public struct BlurContainer<Source: View, Overlay: View>: UIViewControllerRepresentable {

    // MARK: - Properties

    public let iterations: Int
    public let offset: Float

    private let source: Source?
    private let overlay: Overlay
    private let textureProvider: (() -> MTLTexture?)?

    // MARK: - Initialization

    /// Creates a blur container with a SwiftUI source view and an overlay.
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

    // MARK: - UIViewControllerRepresentable

    public func makeUIViewController(context: Context) -> BlurContainerViewController<Overlay> {
        let vc = BlurContainerViewController<Overlay>()
        vc.loadViewIfNeeded()

        vc.blurView.iterations = iterations
        vc.blurView.offset = offset

        if let textureProvider {
            vc.blurView.textureProvider = textureProvider
        } else if let source {
            let sourceHosting = UIHostingController(rootView: source)
            sourceHosting.view.backgroundColor = .clear
            vc.blurView.sourceView = sourceHosting.view
            context.coordinator.sourceHosting = sourceHosting
        }

        vc.configureOverlay(overlay)

        return vc
    }

    public func updateUIViewController(
        _ uiViewController: BlurContainerViewController<Overlay>,
        context: Context
    ) {
        uiViewController.blurView.iterations = iterations
        uiViewController.blurView.offset = offset

        if textureProvider != nil {
            uiViewController.blurView.textureProvider = textureProvider
        } else if let source {
            context.coordinator.sourceHosting?.rootView = source
        }

        uiViewController.configureOverlay(overlay)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var sourceHosting: UIHostingController<Source>?
    }
}

// MARK: - Convenience: No Overlay

@available(iOS 13.0, *)
public extension BlurContainer where Overlay == EmptyView {

    /// Creates a blur container without an overlay.
    init(
        iterations: Int = 3,
        offset: Float = 2.0,
        @ViewBuilder source: () -> Source
    ) {
        self.init(iterations: iterations, offset: offset, source: source) { EmptyView() }
    }
}

// MARK: - Metal Texture Provider

@available(iOS 13.0, *)
public extension BlurContainer where Source == EmptyView {

    /// Creates a blur container that takes a Metal texture directly each frame.
    /// Use this for Metal-rendered content (e.g. MTKView-based animations).
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

// MARK: - BlurContainerViewController

/// The view controller that `BlurContainer` vends to SwiftUI.
///
/// Because SwiftUI calls `addChild`/`didMove(toParent:)` automatically for
/// `UIViewControllerRepresentable`, this VC is correctly placed in the hierarchy.
/// The overlay hosting controller is then added as a *child* of this VC, which
/// propagates safe area insets and navigation context correctly into the overlay.
@available(iOS 13.0, *)
public final class BlurContainerViewController<Overlay: View>: UIViewController {

    /// The underlying Metal blur view. Available after `loadViewIfNeeded()`.
    public private(set) var blurView: BlurContainerView!

    private var overlayHosting: UIHostingController<Overlay>?

    public override func loadView() {
        blurView = BlurContainerView()
        view = blurView
    }

    /// Installs or updates the overlay hosting controller.
    /// A no-op when `Overlay == EmptyView`.
    func configureOverlay(_ overlay: Overlay) {
        guard Overlay.self != EmptyView.self else { return }

        if let existing = overlayHosting {
            existing.rootView = overlay
        } else {
            let hosting = UIHostingController(rootView: overlay)
            hosting.view.backgroundColor = .clear
            addChild(hosting)
            blurView.overlayView = hosting.view
            hosting.didMove(toParent: self)
            overlayHosting = hosting
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
