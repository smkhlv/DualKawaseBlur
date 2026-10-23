import Metal
import Synchronization
import Testing
import UIKit
import QuartzCore
@testable import DualKawaseBlur

@Test @MainActor func nilAndNoOutputBackingStaysOpaqueAndUncoveredThroughInitialSetup() throws {
    let session = try makeControllerTestSession()
    let color = UIColor(red: 0.12, green: 0.23, blue: 0.34, alpha: 0.24)
    let controller = SharedMetalBackgroundController(session: nil, baseColor: color)
    controller.loadView()
    defer { session.finish() }

    func expectOpaqueUncoveredBacking() {
        let backing = controller.view!
        #expect(backing.isOpaque)
        expectOpaque(backing.backgroundColor, red: 0.12, green: 0.23, blue: 0.34)
        #expect(backing.subviews.count == 2)
        let surface = backing.subviews[0]
        let cover = backing.subviews[1]
        guard let layer = surface.layer as? CAMetalLayer else {
            Issue.record("Presenter surface is not backed by CAMetalLayer.")
            return
        }
        #expect(surface.isOpaque)
        expectOpaque(surface.backgroundColor, red: 0.12, green: 0.23, blue: 0.34)
        expectOpaque(layer.backgroundColor.map(UIColor.init(cgColor:)), red: 0.12, green: 0.23, blue: 0.34)
        #expect(cover.isOpaque)
        #expect(cover.isHidden)
        expectOpaque(cover.backgroundColor, red: 0.12, green: 0.23, blue: 0.34)
    }

    expectOpaqueUncoveredBacking()
    controller.update(session: session, baseColor: color)
    expectOpaqueUncoveredBacking()

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    controller.view.frame = window.bounds
    window.addSubview(controller.view)
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    controller.view.layoutIfNeeded()
    expectOpaqueUncoveredBacking()
    controller.view.removeFromSuperview()
}

@Test func opaqueBaseColorResolvesDynamicTraitColorAndDiscardsInputAlpha() {
    let dynamic = UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            UIColor(red: 0.7, green: 0.4, blue: 0.2, alpha: 0.1)
        } else {
            UIColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 0.35)
        }
    }

    expectOpaque(
        SharedOpaqueBaseColor.resolve(dynamic, traits: UITraitCollection(userInterfaceStyle: .light)),
        red: 0.1,
        green: 0.3,
        blue: 0.8
    )
    expectOpaque(
        SharedOpaqueBaseColor.resolve(dynamic, traits: UITraitCollection(userInterfaceStyle: .dark)),
        red: 0.7,
        green: 0.4,
        blue: 0.2
    )
}

@Test @MainActor func visibleControllerReplacingNilSessionRequestsReplay() throws {
    let session = try makeControllerTestSession()
    let events = ReplayEvents()
    session.setDiagnosticHandler { events.record($0) }
    let baseColor = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    let controller = SharedMetalBackgroundController(session: nil, baseColor: baseColor)
    controller.loadView()
    transition(controller, appearing: true)
    defer {
        transition(controller, appearing: false)
        session.finish()
    }

    controller.update(session: session, baseColor: baseColor)

    #expect(events.replayCount == 1)
}

@Test @MainActor func visibleSessionReplacementReplaysButHiddenReplacementWaitsForAppearance() throws {
    let firstSession = try makeControllerTestSession()
    let secondSession = try makeControllerTestSession()
    let hiddenSession = try makeControllerTestSession()
    let firstEvents = ReplayEvents()
    let secondEvents = ReplayEvents()
    let hiddenEvents = ReplayEvents()
    firstSession.setDiagnosticHandler { firstEvents.record($0) }
    secondSession.setDiagnosticHandler { secondEvents.record($0) }
    hiddenSession.setDiagnosticHandler { hiddenEvents.record($0) }
    let baseColor = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    let controller = SharedMetalBackgroundController(session: firstSession, baseColor: baseColor)
    controller.loadView()
    transition(controller, appearing: true)
    defer {
        transition(controller, appearing: false)
        firstSession.finish()
        secondSession.finish()
        hiddenSession.finish()
    }

    controller.update(session: secondSession, baseColor: baseColor)
    #expect(firstEvents.replayCount == 1)
    #expect(secondEvents.replayCount == 1)

    transition(controller, appearing: false)
    controller.update(session: hiddenSession, baseColor: baseColor)
    #expect(hiddenEvents.replayCount == 0)

    transition(controller, appearing: true)
    #expect(hiddenEvents.replayCount == 1)
}

@Test @MainActor func staticOutputReplaysAfterVisibleControllerReattachesAtSameBounds() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let consumed = Mutex(0)
    let texture = try TestTexture.impulse(device: device, width: 32, height: 32)
    source.publish(MetalBlurFrame(texture: texture) {
        consumed.withLock { $0 += 1 }
    })
    let session = try SharedMetalBlurSession(source: source, device: device)
    let events = ReplayEvents()
    session.setDiagnosticHandler { events.record($0) }
    session.renderLatest()
    defer { session.finish() }

    for _ in 0..<300 where events.publishedCount == 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(events.publishedCount == 1)
    #expect(consumed.withLock { $0 } == 1)
    let originalOutput = try #require(session.acquireLatestOutput())
    let sequence = originalOutput.sequence
    originalOutput.release()

    let color = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
    let controller = SharedMetalBackgroundController(session: nil, baseColor: color)
    controller.loadView()
    transition(controller, appearing: true)
    controller.update(session: session, baseColor: color)
    #expect(events.replayCount == 1)
    #expect(events.submissionCount == 0)

    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    controller.view.frame = window.bounds
    window.addSubview(controller.view)
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    controller.view.layoutIfNeeded()
    for _ in 0..<300 where events.handoffCount == 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(events.handoffCount > 0)
    #expect(events.firstScheduledIndex >= 0)
    #expect(events.firstCompletedIndex > events.firstScheduledIndex)
    #expect(events.handoffCoverStates.first == false)
    let firstSubmissionCount = events.submissionCount
    #expect(firstSubmissionCount > 0)

    transition(controller, appearing: false)
    controller.view.removeFromSuperview()
    let priorReplayCount = events.replayCount
    transition(controller, appearing: true)
    #expect(events.replayCount > priorReplayCount)
    #expect(events.submissionCount == firstSubmissionCount)

    let handoffsBeforeReturn = events.handoffCoverStates.count
    window.addSubview(controller.view)
    window.layoutIfNeeded()
    controller.view.layoutIfNeeded()
    for _ in 0..<300 where events.handoffCoverStates.count <= handoffsBeforeReturn {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(events.handoffCoverStates.count > handoffsBeforeReturn)
    #expect(events.handoffCoverStates.last == false)
    #expect(events.submissionCount > firstSubmissionCount)
    #expect(consumed.withLock { $0 } == 1)
    let replayedOutput = try #require(session.acquireLatestOutput())
    #expect(replayedOutput.sequence == sequence)
    replayedOutput.release()

    let handoffsBeforeViewportChange = events.handoffCoverStates.count
    let previousPresenterGeometry = events.presentationGeometry.last
    controller.view.frame = CGRect(x: 0, y: 20, width: 390, height: 844)
    controller.view.layoutIfNeeded()
    for _ in 0..<300 where events.handoffCoverStates.count <= handoffsBeforeViewportChange {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(events.handoffCoverStates.count > handoffsBeforeViewportChange)
    #expect(events.handoffCoverStates.last == true)
    #expect(events.presentationGeometry.last != previousPresenterGeometry)

    transition(controller, appearing: false)
    controller.view.removeFromSuperview()
}

@MainActor
private func transition(_ controller: UIViewController, appearing: Bool) {
    controller.beginAppearanceTransition(appearing, animated: false)
    controller.endAppearanceTransition()
}

@MainActor
private final class ReplayEvents {
    private(set) var messages: [String] = []
    private(set) var replayCount = 0
    private(set) var submissionCount = 0
    private(set) var publishedCount = 0
    private(set) var handoffCount = 0
    private(set) var handoffCoverStates: [Bool] = []
    private(set) var presentationGeometry: [String] = []
    var firstScheduledIndex: Int { messages.firstIndex(where: { $0.contains("present-scheduled=") }) ?? -1 }
    var firstCompletedIndex: Int { messages.firstIndex(where: { $0.contains("gpu-complete=") }) ?? -1 }

    func record(_ event: String) {
        messages.append(event)
        if event.contains("replay-requested") { replayCount += 1 }
        if event.contains("blur output published") { publishedCount += 1 }
        if event.contains("submit=") { submissionCount += 1 }
        if event.contains("geometry window=") { presentationGeometry.append(event) }
        if event.contains("gpu-complete=") || event.contains("device-presented=") {
            handoffCount += 1
            if let marker = event.range(of: "underCover=") {
                handoffCoverStates.append(event[marker.upperBound...].hasPrefix("true"))
            }
        }
    }
}

@MainActor
private func makeControllerTestSession() throws -> SharedMetalBlurSession {
    guard let device = MTLCreateSystemDefaultDevice() else {
        Issue.record("Metal is unavailable in this test environment.")
        throw ControllerTestError.metalUnavailable
    }
    return try SharedMetalBlurSession(source: MetalBlurFrameSource(), device: device)
}

private enum ControllerTestError: Error {
    case metalUnavailable
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
