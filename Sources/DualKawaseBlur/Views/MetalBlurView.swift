import SwiftUI
import UIKit

/// SwiftUI surface for GPU-to-GPU blur of animated Metal frames.
@MainActor
public struct MetalBlurView<Overlay: View>: UIViewControllerRepresentable {
    private let source: MetalBlurFrameSource
    private let configuration: BlurConfiguration
    private let onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?
    private let overlay: Overlay

    public init(
        source: MetalBlurFrameSource,
        configuration: BlurConfiguration = .init(),
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)? = nil,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.source = source
        self.configuration = configuration
        self.onError = onError
        self.overlay = overlay()
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        MetalBlurViewController(
            source: source,
            configuration: configuration,
            onError: onError,
            overlay: overlay
        )
    }

    public func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let controller = controller as? MetalBlurViewController<Overlay> else { return }
        controller.update(
            source: source,
            configuration: configuration,
            onError: onError,
            overlay: overlay
        )
    }
}

public extension MetalBlurView where Overlay == EmptyView {
    init(
        source: MetalBlurFrameSource,
        configuration: BlurConfiguration = .init(),
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)? = nil
    ) {
        self.init(source: source, configuration: configuration, onError: onError) { EmptyView() }
    }
}

@MainActor
final class MetalBlurViewController<Overlay: View>: UIViewController {
    private(set) var renderView: MetalBlurRenderView?
    private let overlayController: UIHostingController<Overlay>
    private let errorRelay: MetalBlurErrorRelay
    private var source: MetalBlurFrameSource

    init(
        source: MetalBlurFrameSource,
        configuration: BlurConfiguration,
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?,
        overlay: Overlay
    ) {
        self.source = source
        let relay = MetalBlurErrorRelay(callback: onError)
        errorRelay = relay
        do {
            renderView = try MetalBlurRenderView(
                source: source,
                configuration: configuration,
                onError: { [relay] error in relay.call(error) }
            )
        } catch let error as DualKawaseBlurError {
            renderView = nil
            errorRelay.call(error)
        } catch {
            renderView = nil
            errorRelay.call(.metalUnavailable)
        }
        overlayController = UIHostingController(rootView: overlay)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        installRenderViewIfAvailable()

        addChild(overlayController)
        overlayController.view.backgroundColor = .clear
        overlayController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayController.view)
        NSLayoutConstraint.activate([
            overlayController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayController.view.topAnchor.constraint(equalTo: view.topAnchor),
            overlayController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        overlayController.didMove(toParent: self)
    }

    func update(
        source: MetalBlurFrameSource,
        configuration: BlurConfiguration,
        onError: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?,
        overlay: Overlay
    ) {
        errorRelay.callback = onError
        if self.source !== source {
            renderView?.teardown()
            renderView?.removeFromSuperview()
            self.source = source
            do {
                renderView = try MetalBlurRenderView(
                    source: source,
                    configuration: configuration,
                    onError: { [errorRelay] error in errorRelay.call(error) }
                )
                installRenderViewIfAvailable()
            } catch let error as DualKawaseBlurError {
                renderView = nil
                errorRelay.call(error)
            } catch {
                renderView = nil
                errorRelay.call(.metalUnavailable)
            }
        }
        renderView?.update(configuration: configuration)
        overlayController.rootView = overlay
    }

    private func installRenderViewIfAvailable() {
        guard isViewLoaded, let renderView else { return }
        renderView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(renderView, at: 0)
        NSLayoutConstraint.activate([
            renderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderView.topAnchor.constraint(equalTo: view.topAnchor),
            renderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

@MainActor
private final class MetalBlurErrorRelay {
    var callback: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?

    init(callback: (@MainActor @Sendable (DualKawaseBlurError) -> Void)?) {
        self.callback = callback
    }

    func call(_ error: DualKawaseBlurError) {
        callback?(error)
    }
}
