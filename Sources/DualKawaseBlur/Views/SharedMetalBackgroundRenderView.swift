import Metal
import QuartzCore
import SwiftUI
import UIKit

@MainActor
public final class SharedMetalBackgroundController: UIViewController {
    private let presenterID = UUID()
    private var session: SharedMetalBlurSession?
    private var baseColor: UIColor
    private var renderView: SharedMetalBackgroundRenderView!
    private var isVisible = false

    init(session: SharedMetalBlurSession?, baseColor: UIColor) {
        self.session = session
        self.baseColor = baseColor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func loadView() {
        renderView = SharedMetalBackgroundRenderView(session: session, baseColor: baseColor)
        renderView.translatesAutoresizingMaskIntoConstraints = false
        view = renderView
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        emitLifecycle("viewWillAppear", animated: animated)
        startPresenting()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        emitLifecycle("viewDidAppear", animated: animated)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        emitLifecycle("viewDidDisappear", animated: animated)
        stopPresenting()
    }

    private func emitLifecycle(_ name: String, animated: Bool) {
        let transition = transitionCoordinator
        session?.diagnostic(
            "controller \(name) animated=\(animated) transitionDuration=\(transition?.transitionDuration ?? 0) transitionAnimated=\(transition?.isAnimated ?? false) inheritedAnimationDuration=\(UIView.inheritedAnimationDuration)"
        )
    }

    func update(session: SharedMetalBlurSession?, baseColor: UIColor) {
        guard self.session !== session || !self.baseColor.isEqual(baseColor) else { return }
        let sessionChanged = self.session !== session
        let wasVisible = isVisible
        if sessionChanged {
            if wasVisible { stopPresenting() }
            self.session = session
        }
        self.baseColor = baseColor
        renderView.set(session: session, baseColor: baseColor)
        if wasVisible, sessionChanged { startPresenting() }
    }

    func stopPresenting() {
        guard isVisible else { return }
        isVisible = false
        session?.unregisterPresenter(id: presenterID)
        renderView.setVisible(false)
    }

    private func startPresenting() {
        isVisible = true
        renderView.setVisible(true)
        guard let session else { return }
        session.registerPresenter(id: presenterID) { [weak renderView] in
            renderView?.requestReplay()
        }
    }
}

@MainActor
final class SharedMetalBackgroundRenderView: UIView {
    private final class SurfaceView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    }

    private let surfaceID = String(UUID().uuidString.prefix(8))
    private let surface = SurfaceView(frame: .zero)
    private let firstPresentationCover = UIView(frame: .zero)
    private var session: SharedMetalBlurSession?
    private var baseColor: UIColor
    private var appliedOpaqueBaseColor = UIColor.clear
    private let presentationOperations: SharedBackgroundPresentationOperations
    private var visible = false
    private var drawInFlight = false
    private var revealState = SharedBackgroundRevealState()
    private var surfaceGeneration: UInt64 { revealState.generation }
    private var lastDrawableSize = CGSize.zero
    private var lastPresentationGeometry: SharedBackgroundPresentationGeometry?
    private var lastWindowScale: CGFloat = 0
    private var hasValidAttachedGeometry = false
    private var submittedDraws = 0
    private var submittedSequence: UInt64 = 0
    private var submittedGeneration: UInt64 = 0
    private var didLogFirstAttachedLayout = false

    init(
        session: SharedMetalBlurSession?,
        baseColor: UIColor,
        presentationOperations: SharedBackgroundPresentationOperations = .live
    ) {
        self.session = session
        self.baseColor = baseColor
        self.presentationOperations = presentationOperations
        super.init(frame: .zero)
        isOpaque = true
        surface.isOpaque = true
        surface.isUserInteractionEnabled = false
        surface.metalLayer.device = session?.device
        surface.metalLayer.pixelFormat = .bgra8Unorm
        surface.metalLayer.framebufferOnly = true
        surface.metalLayer.isOpaque = true
        surface.metalLayer.allowsNextDrawableTimeout = true
        surface.metalLayer.presentsWithTransaction = false
        firstPresentationCover.isOpaque = true
        firstPresentationCover.isHidden = !revealState.coverVisible
        applyOpaqueBaseColor()
        addSubview(surface)
        addSubview(firstPresentationCover)
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitDisplayScale.self,
            UITraitAccessibilityContrast.self
        ]) { (view: SharedMetalBackgroundRenderView, _) in
            view.applyOpaqueBaseColor()
            view.refreshPresentationGeometry(reason: "traits", requestDraw: true)
        }
        emit("created generation=\(surfaceGeneration)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        firstPresentationCover.frame = bounds
        #if DEBUG
        if window != nil, !didLogFirstAttachedLayout {
            didLogFirstAttachedLayout = true
            emit("first-attached-layout bounds=\(bounds) \(coverDiagnosticState())")
        }
        #endif
        refreshPresentationGeometry(reason: "layout", requestDraw: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshPresentationGeometry(reason: "window", requestDraw: true)
    }

    private func refreshPresentationGeometry(reason: String, requestDraw: Bool) {
        let scale = window?.screen.scale ?? (lastWindowScale > 0 ? lastWindowScale : traitCollection.displayScale)
        let newSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        surface.contentScaleFactor = scale
        surface.metalLayer.contentsScale = scale
        let sizeChanged = newSize != lastDrawableSize || scale != lastWindowScale
        if sizeChanged {
            lastDrawableSize = newSize
            lastWindowScale = scale
            surface.metalLayer.drawableSize = newSize
        }

        let newGeometry: SharedBackgroundPresentationGeometry?
        if let window {
            let presenterRect = surface.convert(surface.bounds, to: window)
            newGeometry = SharedBackgroundPresentationGeometry(
                windowIdentity: ObjectIdentifier(window),
                windowRectOnScreen: window.convert(window.bounds, to: nil),
                windowBounds: window.bounds,
                presenterRect: presenterRect,
                displayScale: scale,
                baseColor: resolvedOpaqueColor()
            )
        } else {
            newGeometry = nil
        }
        let attachedNow = newGeometry != nil
        let attachmentChanged = attachedNow != hasValidAttachedGeometry
        let geometryChanged = attachedNow && newGeometry != lastPresentationGeometry
        guard sizeChanged || geometryChanged || attachmentChanged else { return }

        if attachedNow { lastPresentationGeometry = newGeometry }
        hasValidAttachedGeometry = attachedNow
        advanceSurfaceGeneration(incompatible: sizeChanged || geometryChanged)
        let transition = attachmentChanged ? (attachedNow ? "attached" : "detached") : "updated"
        emit("geometry-change reason=\(reason) transition=\(transition) generation=\(surfaceGeneration) pixels=\(Int(newSize.width))x\(Int(newSize.height)) mapping=\(newGeometry?.mapping as Any) covered=\(!firstPresentationCover.isHidden)")
        if visible && requestDraw && attachedNow { drawLatest() }
    }

    func set(session: SharedMetalBlurSession?, baseColor: UIColor) {
        if self.session !== session {
            self.session = session
            advanceSurfaceGeneration(incompatible: true)
            surface.metalLayer.device = session?.device
            emit("session-change generation=\(surfaceGeneration)")
        }
        self.baseColor = baseColor
        applyOpaqueBaseColor()
        refreshPresentationGeometry(reason: "base-or-session", requestDraw: false)
        if visible { drawLatest() }
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        advanceSurfaceGeneration(incompatible: false)
        emit("visibility=\(visible) generation=\(surfaceGeneration)")
        if visible { drawLatest() }
    }

    func requestReplay() {
        emit("replay-requested generation=\(surfaceGeneration)")
        drawLatest()
    }

    func drawLatest() {
        guard visible, !drawInFlight, let session else { return }
        refreshPresentationGeometry(reason: "draw", requestDraw: false)
        guard let window = surface.window,
              hasValidAttachedGeometry,
              let geometry = lastPresentationGeometry,
              geometry.windowIdentity == ObjectIdentifier(window) else {
            emit("mapping-unavailable reason=no-window generation=\(surfaceGeneration)")
            return
        }
        let mapping = geometry.mapping
        emit("geometry window=\(geometry.windowBounds) windowScreen=\(geometry.windowRectOnScreen) presenter=\(geometry.presenterRect) scale=\(geometry.displayScale) base=\(geometry.baseColor) uvOrigin=\(mapping.origin) uvScale=\(mapping.scale)")
        guard let output = session.acquireLatestOutput() else { return }
        let outputSequence = output.sequence
        #if DEBUG
        let nextDrawableStart = CACurrentMediaTime()
        emit("nextDrawable-BEGIN generation=\(surfaceGeneration) \(coverDiagnosticState())")
        #endif
        let drawable = presentationOperations.nextDrawable(surface.metalLayer)
        #if DEBUG
        emit("nextDrawable-END generation=\(surfaceGeneration) success=\(drawable != nil) elapsed=\(CACurrentMediaTime() - nextDrawableStart) \(coverDiagnosticState())")
        #endif
        guard let drawable else {
            release(output)
            return
        }
        guard let commandBuffer = presentationOperations.makeCommandBuffer(session) else {
            release(output)
            return
        }
        let color = geometry.baseColor
        let generation = surfaceGeneration
        do {
            try presentationOperations.encodePresentation(
                session,
                output.resource.published,
                drawable.texture,
                color,
                mapping,
                commandBuffer
            )
        } catch {
            release(output)
            session.diagnostic("present encode error surface=\(surfaceID): \(error.localizedDescription)")
            return
        }

        drawInFlight = true
        submittedDraws += 1
        let drawNumber = submittedDraws
        submittedSequence = outputSequence
        submittedGeneration = generation
        emit("submit=\(drawNumber) generation=\(generation)")
        let didReleaseReadLease = presentationOperations.didReleaseReadLease
        #if !targetEnvironment(simulator)
        drawable.addPresentedHandler { [weak self] drawable in
            let presentedTime = drawable.presentedTime
            Task { @MainActor [weak self] in
                self?.didPresent(
                    generation: generation,
                    drawNumber: drawNumber,
                    presentedTime: presentedTime,
                    sequence: outputSequence
                )
            }
        }
        #endif
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let callbackUptime = CACurrentMediaTime()
            output.release()
            didReleaseReadLease()
            let succeeded = buffer.status == .completed
            #if DEBUG
            print("[SharedMetalBackground] t=\(callbackUptime) stage=gpu-completion-callback draw=\(drawNumber) success=\(succeeded)")
            #endif
            Task { @MainActor [weak self] in
                #if DEBUG
                let mainActorUptime = CACurrentMediaTime()
                self?.emit("gpu-completion-mainactor draw=\(drawNumber) callbackToMainActor=\(mainActorUptime - callbackUptime) \(self?.coverDiagnosticState() ?? "view-released")")
                #endif
                self?.didComplete(
                    succeeded,
                    drawNumber: drawNumber,
                    generation: generation,
                    sequence: outputSequence,
                    callbackUptime: callbackUptime
                )
            }
        }
        commandBuffer.present(drawable)
        #if DEBUG
        emit("present-scheduled=\(drawNumber) generation=\(generation) sequence=\(outputSequence) \(coverDiagnosticState())")
        emit("command-buffer-commit draw=\(drawNumber) \(coverDiagnosticState())")
        #endif
        commandBuffer.commit()
        #if DEBUG
        emit("command-buffer-commit-return draw=\(drawNumber)")
        #endif
    }

    private func didPresent(
        generation: UInt64,
        drawNumber: Int,
        presentedTime: CFTimeInterval,
        sequence: UInt64
    ) {
        guard generation == surfaceGeneration, visible else {
            emit("stale-present draw=\(drawNumber) generation=\(generation)")
            return
        }
        guard presentedTime > 0 else {
            emit("presented-callback-skipped draw=\(drawNumber) generation=\(generation)")
            return
        }
        let result = revealState.acknowledge(generation: generation, succeeded: true, visible: visible)
        guard result != .stale, result != .ignored else { return }
        syncCoverWithRevealState()
        let covered = result == .replacementContentConfirmed
        emit("device-presented=\(drawNumber) generation=\(generation) sequence=\(sequence) underCover=\(covered) presentedTime=\(presentedTime)")
    }

    private func didComplete(
        _ succeeded: Bool,
        drawNumber: Int,
        generation: UInt64,
        sequence: UInt64,
        callbackUptime: CFTimeInterval
    ) {
        drawInFlight = false
        let covered = revealState.coverVisible
        #if DEBUG
        emit("gpu-complete-mainactor draw=\(drawNumber) callbackToMainActor=\(CACurrentMediaTime() - callbackUptime) \(coverDiagnosticState())")
        #endif
        emit("gpu-complete=\(succeeded) draw=\(drawNumber) generation=\(generation) sequence=\(sequence) underCover=\(covered)")
        #if targetEnvironment(simulator)
        let result = revealState.acknowledge(generation: generation, succeeded: succeeded, visible: visible)
        if result == .replacementContentConfirmed {
            syncCoverWithRevealState()
            emit("replacement-cover-gpu-ack draw=\(drawNumber) generation=\(generation) sequence=\(sequence)")
        } else if result == .initialContentConfirmed {
            emit("initial-content-gpu-confirmation draw=\(drawNumber) generation=\(generation) sequence=\(sequence)")
        }
        #endif
        redrawIfLatestAdvanced()
    }

    private func redrawIfLatestAdvanced() {
        guard visible, let session, let latest = session.acquireLatestOutput() else { return }
        let hasNewerOutput = latest.sequence > submittedSequence
        latest.release()
        if hasNewerOutput || submittedGeneration != surfaceGeneration { drawLatest() }
    }

    private func emit(_ message: String) {
        session?.diagnostic("surface=\(surfaceID) \(message)")
    }

    @discardableResult
    private func advanceSurfaceGeneration(incompatible: Bool) -> UInt64 {
        let generation = revealState.advanceGeneration(incompatible: incompatible)
        syncCoverWithRevealState()
        return generation
    }

    private func syncCoverWithRevealState() {
        firstPresentationCover.isHidden = !revealState.coverVisible
    }

    #if DEBUG
    private func coverDiagnosticState() -> String {
        let presentationOpacity = firstPresentationCover.layer.presentation()?.opacity as Any
        let animationKeys = firstPresentationCover.layer.animationKeys() ?? []
        return "coverHidden=\(firstPresentationCover.isHidden) coverAlpha=\(firstPresentationCover.alpha) coverLayerOpacity=\(firstPresentationCover.layer.opacity) presentationOpacity=\(presentationOpacity) animations=\(animationKeys) txDuration=\(CATransaction.animationDuration()) txDisableActions=\(CATransaction.disableActions()) inheritedAnimationDuration=\(UIView.inheritedAnimationDuration)"
    }
    #endif

    private func resolvedOpaqueColor() -> SIMD4<Float> {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        appliedOpaqueBaseColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4<Float>(Float(red), Float(green), Float(blue), 1)
    }

    private func applyOpaqueBaseColor() {
        let opaqueColor = SharedOpaqueBaseColor.resolve(baseColor, traits: traitCollection)
        appliedOpaqueBaseColor = opaqueColor
        backgroundColor = opaqueColor
        surface.backgroundColor = opaqueColor
        surface.metalLayer.backgroundColor = opaqueColor.cgColor
        firstPresentationCover.backgroundColor = opaqueColor
    }

    private func release(_ output: SharedOutputFrames<SharedBlurWorkspace>.ReadLease) {
        output.release()
        presentationOperations.didReleaseReadLease()
    }
}

@MainActor
struct SharedBackgroundPresentationOperations {
    let nextDrawable: (CAMetalLayer) -> CAMetalDrawable?
    let makeCommandBuffer: (SharedMetalBlurSession) -> MTLCommandBuffer?
    let encodePresentation: (
        SharedMetalBlurSession,
        MTLTexture,
        MTLTexture,
        SIMD4<Float>,
        SharedBackgroundUVMapping,
        MTLCommandBuffer
    ) throws -> Void
    let didReleaseReadLease: @Sendable () -> Void

    static let live = SharedBackgroundPresentationOperations(
        nextDrawable: { $0.nextDrawable() },
        makeCommandBuffer: { $0.makePresentationCommandBuffer() },
        encodePresentation: { session, output, destination, baseColor, mapping, commandBuffer in
            try session.encodePresentation(
                output: output,
                destination: destination,
                baseColor: baseColor,
                mapping: mapping,
                into: commandBuffer
            )
        },
        didReleaseReadLease: {}
    )
}
