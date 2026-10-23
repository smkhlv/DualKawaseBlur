import Metal
import Synchronization
import Testing
import UIKit
@testable import DualKawaseBlur

private enum InjectedPresentationFailure: Equatable, Sendable {
    case drawable
    case commandBuffer
    case encode
}

private enum PresentationFailure: Error {
    case injected
}

@Test @MainActor func drawWithoutOutputKeepsOpaqueBaseAndDoesNotAcquireDrawableOrLease() throws {
    let session = try makeFailureTestSession()
    let probe = FailurePathProbe()
    let operations = makeFailureOperations(.drawable, probe: probe)
    let color = UIColor(red: 0.26, green: 0.47, blue: 0.68, alpha: 0.2)
    let view = SharedMetalBackgroundRenderView(
        session: session,
        baseColor: color,
        presentationOperations: operations
    )
    let window = attach(view)
    defer {
        view.setVisible(false)
        view.removeFromSuperview()
        session.finish()
        _ = window
    }

    view.setVisible(true)

    #expect(probe.drawableRequests == 0)
    #expect(probe.releasedLeases == 0)
    expectOpaqueBase(view, red: 0.26, green: 0.47, blue: 0.68)
}

@Test @MainActor func failedDrawableCommandBufferAndEncodePathsReleaseActualReadLeases() async throws {
    for failure in [InjectedPresentationFailure.drawable, .commandBuffer, .encode] {
        let session = try await makePublishedFailureTestSession()
        let probe = FailurePathProbe()
        let view = SharedMetalBackgroundRenderView(
            session: session,
            baseColor: UIColor(red: 0.21, green: 0.43, blue: 0.65, alpha: 0.15),
            presentationOperations: makeFailureOperations(failure, probe: probe)
        )
        let window = attach(view)
        defer {
            view.setVisible(false)
            view.removeFromSuperview()
            session.finish()
            _ = window
        }

        view.setVisible(true)

        #expect(probe.drawableRequests == 1)
        #expect(probe.releasedLeases == 1)
        expectOpaqueBase(view, red: 0.21, green: 0.43, blue: 0.65)
        let latest = try #require(session.acquireLatestOutput())
        latest.release()
    }
}

@MainActor
private final class FailurePathProbe {
    private(set) var drawableRequests = 0
    private(set) var releasedLeases = 0

    func requestDrawable(_ layer: CAMetalLayer, for failure: InjectedPresentationFailure) -> CAMetalDrawable? {
        drawableRequests += 1
        if failure == .drawable { return nil }
        return layer.nextDrawable()
    }

    func releaseLease() {
        releasedLeases += 1
    }
}

@MainActor
private func makeFailureOperations(
    _ failure: InjectedPresentationFailure,
    probe: FailurePathProbe
) -> SharedBackgroundPresentationOperations {
    SharedBackgroundPresentationOperations(
        nextDrawable: { layer in probe.requestDrawable(layer, for: failure) },
        makeCommandBuffer: { session in
            if failure == .commandBuffer { return nil }
            return session.makePresentationCommandBuffer()
        },
        encodePresentation: { session, output, destination, baseColor, mapping, commandBuffer in
            if failure == .encode { throw PresentationFailure.injected }
            try session.encodePresentation(
                output: output,
                destination: destination,
                baseColor: baseColor,
                mapping: mapping,
                into: commandBuffer
            )
        },
        didReleaseReadLease: { MainActor.assumeIsolated { probe.releaseLease() } }
    )
}

@MainActor
private func makeFailureTestSession() throws -> SharedMetalBlurSession {
    guard let device = MTLCreateSystemDefaultDevice() else {
        Issue.record("Metal is unavailable in this test environment.")
        throw FailureTestError.metalUnavailable
    }
    return try SharedMetalBlurSession(source: MetalBlurFrameSource(), device: device)
}

@MainActor
private func makePublishedFailureTestSession() async throws -> SharedMetalBlurSession {
    guard let device = MTLCreateSystemDefaultDevice() else {
        Issue.record("Metal is unavailable in this test environment.")
        throw FailureTestError.metalUnavailable
    }
    let source = MetalBlurFrameSource()
    let texture = try TestTexture.impulse(device: device, width: 32, height: 32)
    source.publish(MetalBlurFrame(texture: texture))
    let session = try SharedMetalBlurSession(source: source, device: device)
    session.renderLatest()
    for _ in 0..<300 {
        if let latest = session.acquireLatestOutput() {
            latest.release()
            return session
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    session.finish()
    Issue.record("The seeded output did not become available for the failure-path test.")
    throw FailureTestError.outputUnavailable
}

@MainActor
private func attach(_ view: UIView) -> UIWindow {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    view.frame = window.bounds
    window.addSubview(view)
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    view.layoutIfNeeded()
    return window
}

@MainActor
private func expectOpaqueBase(_ view: SharedMetalBackgroundRenderView, red: CGFloat, green: CGFloat, blue: CGFloat) {
    #expect(view.isOpaque)
    expectOpaque(view.backgroundColor, red: red, green: green, blue: blue)
    #expect(view.subviews.count == 2)
    expectOpaque(view.subviews[0].backgroundColor, red: red, green: green, blue: blue)
    expectOpaque(view.subviews[1].backgroundColor, red: red, green: green, blue: blue)
    #expect(view.subviews[1].isHidden)
    guard let metalLayer = view.subviews[0].layer as? CAMetalLayer,
          let layerColor = metalLayer.backgroundColor else {
        Issue.record("Expected a CAMetalLayer with its safe opaque base color.")
        return
    }
    expectOpaque(UIColor(cgColor: layerColor), red: red, green: green, blue: blue)
}

private enum FailureTestError: Error {
    case metalUnavailable
    case outputUnavailable
}

private func expectOpaque(
    _ color: UIColor?,
    red expectedRed: CGFloat,
    green expectedGreen: CGFloat,
    blue expectedBlue: CGFloat
) {
    guard let color else {
        Issue.record("Expected an opaque backing color.")
        return
    }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    #expect(abs(red - expectedRed) < 0.005)
    #expect(abs(green - expectedGreen) < 0.005)
    #expect(abs(blue - expectedBlue) < 0.005)
    #expect(abs(alpha - 1) < 0.005)
}
