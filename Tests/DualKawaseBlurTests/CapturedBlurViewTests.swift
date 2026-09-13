import Metal
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import DualKawaseBlur

@MainActor
@Test func captureAcquiresItsSlotBeforeRendering() {
    let pool = FramePool(resources: ["capture-slot"])
    var events: [String] = []
    let driver = CapturedFrameDriver(
        pool: pool,
        capture: { resource in
            #expect(resource == "capture-slot")
            #expect(pool.availableCount == 0)
            events.append("capture")
        },
        nextDrawable: {
            events.append("drawable")
            return CapturedFakeDrawable()
        },
        submit: { _, _, completion in
            events.append("submit")
            completion(nil)
        },
        onError: nil
    )

    driver.tick()

    #expect(events == ["capture", "drawable", "submit"])
    #expect(pool.availableCount == 1)
}

@MainActor
@Test func captureEncodeFailureReturnsItsSlot() {
    let errors = Mutex<[DualKawaseBlurError]>([])
    let pool = FramePool(resources: [0])
    let driver = CapturedFrameDriver(
        pool: pool,
        capture: { _ in },
        nextDrawable: { CapturedFakeDrawable() },
        submit: { _, _, _ in throw DualKawaseBlurError.unsupportedTexture },
        onError: { error in errors.withLock { $0.append(error) } }
    )

    driver.tick()

    #expect(pool.availableCount == 1)
    #expect(errors.withLock { $0 } == [.unsupportedTexture])
}

@MainActor
@Test func captureResizeRetainsOldInflightResourceUntilCompletion() {
    weak var oldResource: CapturedResourceProbe?
    var completion: (@Sendable (DualKawaseBlurError?) -> Void)?
    let pool: FramePool<CapturedResourceProbe>
    do {
        let resource = CapturedResourceProbe(id: "old")
        oldResource = resource
        pool = FramePool(resources: [resource])
    }
    let driver = CapturedFrameDriver(
        pool: pool,
        capture: { _ in },
        nextDrawable: { CapturedFakeDrawable() },
        submit: { _, _, handler in completion = handler },
        onError: nil
    )

    driver.tick()
    pool.replace(with: [CapturedResourceProbe(id: "new")])
    #expect(oldResource != nil)

    completion?(nil)
    #expect(oldResource == nil)
    #expect(pool.availableCount == 1)
}

@MainActor
@Test func capturedViewContainsSourceAndOverlayAsChildControllers() throws {
    let controller = CapturedBlurViewController(
        configuration: .init(),
        onError: nil,
        source: Text("Source"),
        overlay: Text("Overlay")
    )

    controller.loadViewIfNeeded()

    #expect(controller.sourceController.parent === controller)
    #expect(controller.overlayController.parent === controller)
    #expect(controller.sourceController.view.superview === controller.view)
    #expect(controller.overlayController.view.superview === controller.view)
    if let renderView = controller.renderView {
        let sourceIndex = try #require(controller.view.subviews.firstIndex(of: controller.sourceController.view))
        let renderIndex = try #require(controller.view.subviews.firstIndex(of: renderView))
        let overlayIndex = try #require(controller.view.subviews.firstIndex(of: controller.overlayController.view))
        #expect(sourceIndex < renderIndex)
        #expect(renderIndex < overlayIndex)
    }
}

private final class CapturedResourceProbe: Sendable {
    let id: String

    init(id: String) {
        self.id = id
    }
}

private final class CapturedFakeDrawable {}
