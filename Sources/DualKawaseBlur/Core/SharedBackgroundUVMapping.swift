import CoreGraphics
import UIKit
import simd

/// Maps presenter-local Metal UVs to the shared texture's canonical window viewport.
struct SharedBackgroundUVMapping: Equatable, Sendable {
    let origin: SIMD2<Float>
    let scale: SIMD2<Float>

    static let unit = SharedBackgroundUVMapping(origin: .zero, scale: SIMD2<Float>(repeating: 1))

    init(origin: SIMD2<Float>, scale: SIMD2<Float>) {
        self.origin = origin
        self.scale = scale
    }

    init?(windowBounds: CGRect, presenterRect: CGRect) {
        let values = [
            windowBounds.minX, windowBounds.minY, windowBounds.width, windowBounds.height,
            presenterRect.minX, presenterRect.minY, presenterRect.width, presenterRect.height
        ]
        guard values.allSatisfy(\.isFinite),
              windowBounds.width > 0, windowBounds.height > 0,
              presenterRect.width > 0, presenterRect.height > 0 else {
            return nil
        }

        let origin = SIMD2<Float>(
            Float((presenterRect.minX - windowBounds.minX) / windowBounds.width),
            Float((presenterRect.minY - windowBounds.minY) / windowBounds.height)
        )
        let scale = SIMD2<Float>(
            Float(presenterRect.width / windowBounds.width),
            Float(presenterRect.height / windowBounds.height)
        )
        guard origin.x.isFinite, origin.y.isFinite, scale.x.isFinite, scale.y.isFinite else {
            return nil
        }
        self.init(origin: origin, scale: scale)
    }

    func textureCoordinate(for localUV: SIMD2<Float>) -> SIMD2<Float> {
        origin + localUV * scale
    }
}

struct SharedBackgroundPresentationGeometry: Equatable {
    let windowIdentity: ObjectIdentifier
    let windowRectOnScreen: CGRect
    let windowBounds: CGRect
    let presenterRect: CGRect
    let displayScale: CGFloat
    let mapping: SharedBackgroundUVMapping
    let baseColor: SIMD4<Float>

    init?(
        windowIdentity: ObjectIdentifier,
        windowRectOnScreen: CGRect,
        windowBounds: CGRect,
        presenterRect: CGRect,
        displayScale: CGFloat,
        baseColor: SIMD4<Float>
    ) {
        guard displayScale.isFinite, displayScale > 0,
              baseColor.x.isFinite, baseColor.y.isFinite,
              baseColor.z.isFinite, baseColor.w.isFinite,
              let mapping = SharedBackgroundUVMapping(windowBounds: windowBounds, presenterRect: presenterRect)
        else { return nil }
        let screenRectValues = [windowRectOnScreen.minX, windowRectOnScreen.minY,
                                windowRectOnScreen.width, windowRectOnScreen.height]
        guard screenRectValues.allSatisfy(\.isFinite) else { return nil }
        self.windowIdentity = windowIdentity
        self.windowRectOnScreen = windowRectOnScreen
        self.windowBounds = windowBounds
        self.presenterRect = presenterRect
        self.displayScale = displayScale
        self.mapping = mapping
        self.baseColor = baseColor
    }
}
