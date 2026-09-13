import SwiftUI
import UIKit

/// A SwiftUI surface that CPU-rasterizes arbitrary view content into an IOSurface,
/// blurs it on the GPU, and displays an optional live overlay above the result.
///
/// Capture uses `CALayer.render(in:)`, so compositor-backed video, protected content,
/// and Metal-backed subviews are not guaranteed to appear in the captured image.
@MainActor
public struct CapturedBlurView<Source: View, Overlay: View>: UIViewControllerRepresentable {
    private let configuration: BlurConfiguration
    private let onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?
    private let source: Source
    private let overlay: Overlay

    public init(
        configuration: BlurConfiguration = .init(),
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)? = nil,
        @ViewBuilder source: () -> Source,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.configuration = configuration
        self.onError = onError
        self.source = source()
        self.overlay = overlay()
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        CapturedBlurViewController(
            configuration: configuration,
            onError: onError,
            source: source,
            overlay: overlay
        )
    }

    public func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let controller = controller as? CapturedBlurViewController<Source, Overlay> else {
            return
        }
        controller.update(
            configuration: configuration,
            onError: onError,
            source: source,
            overlay: overlay
        )
    }
}

public extension CapturedBlurView where Overlay == EmptyView {
    init(
        configuration: BlurConfiguration = .init(),
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)? = nil,
        @ViewBuilder source: () -> Source
    ) {
        self.init(configuration: configuration, onError: onError, source: source) {
            EmptyView()
        }
    }
}

@MainActor
final class CapturedBlurViewController<Source: View, Overlay: View>: UIViewController {
    private(set) var renderView: CapturedBlurRenderView?
    let sourceController: UIHostingController<Source>
    let overlayController: UIHostingController<Overlay>

    private let errorRelay: CapturedBlurErrorRelay

    init(
        configuration: BlurConfiguration,
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?,
        source: Source,
        overlay: Overlay
    ) {
        sourceController = UIHostingController(rootView: source)
        overlayController = UIHostingController(rootView: overlay)
        let relay = CapturedBlurErrorRelay(callback: onError)
        errorRelay = relay
        do {
            renderView = try CapturedBlurRenderView(
                sourceView: sourceController.view,
                configuration: configuration,
                onError: { [relay] error in relay.call(error) }
            )
        } catch let error as DualKawaseBlurError {
            renderView = nil
            relay.call(error)
        } catch {
            renderView = nil
            relay.call(.metalUnavailable)
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        install(sourceController, at: 0)
        installRenderViewIfAvailable()
        install(overlayController, at: view.subviews.count)
    }

    func update(
        configuration: BlurConfiguration,
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?,
        source: Source,
        overlay: Overlay
    ) {
        errorRelay.callback = onError
        sourceController.rootView = source
        overlayController.rootView = overlay
        renderView?.update(configuration: configuration)
    }

    private func install<Content: View>(
        _ controller: UIHostingController<Content>,
        at index: Int
    ) {
        addChild(controller)
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(controller.view, at: index)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        controller.didMove(toParent: self)
    }

    private func installRenderViewIfAvailable() {
        guard let renderView else { return }
        renderView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(renderView, at: min(1, view.subviews.count))
        NSLayoutConstraint.activate([
            renderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderView.topAnchor.constraint(equalTo: view.topAnchor),
            renderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

@MainActor
private final class CapturedBlurErrorRelay {
    var callback: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?

    init(callback: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?) {
        self.callback = callback
    }

    func call(_ error: DualKawaseBlurError) {
        callback?(error)
    }
}
