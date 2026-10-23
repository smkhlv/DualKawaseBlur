import CoreGraphics
import Testing
import UIKit
@testable import DualKawaseBlur

@Test func fullWindowUsesUnitUVMapping() throws {
    let window = CGRect(x: 0, y: 0, width: 390, height: 844)
    let mapping = try #require(SharedBackgroundUVMapping(windowBounds: window, presenterRect: window))

    #expect(mapping == .unit)
    #expect(mapping.textureCoordinate(for: SIMD2<Float>(0.25, 0.75)) == SIMD2<Float>(0.25, 0.75))
}

@Test func differentContentRectsMapOverlappingWindowPointsToTheSameTextureCoordinate() throws {
    let window = CGRect(x: 0, y: 0, width: 390, height: 844)
    let largeTitleContent = CGRect(x: 0, y: 100, width: 390, height: 744)
    let inlineTitleContent = CGRect(x: 0, y: 50, width: 390, height: 794)
    let largeTitleMapping = try #require(
        SharedBackgroundUVMapping(windowBounds: window, presenterRect: largeTitleContent)
    )
    let inlineTitleMapping = try #require(
        SharedBackgroundUVMapping(windowBounds: window, presenterRect: inlineTitleContent)
    )
    let windowPoint = CGPoint(x: 195, y: 200)
    let largeLocalUV = SIMD2<Float>(
        Float((windowPoint.x - largeTitleContent.minX) / largeTitleContent.width),
        Float((windowPoint.y - largeTitleContent.minY) / largeTitleContent.height)
    )
    let inlineLocalUV = SIMD2<Float>(
        Float((windowPoint.x - inlineTitleContent.minX) / inlineTitleContent.width),
        Float((windowPoint.y - inlineTitleContent.minY) / inlineTitleContent.height)
    )

    let largeTitleUV = largeTitleMapping.textureCoordinate(for: largeLocalUV)
    let inlineTitleUV = inlineTitleMapping.textureCoordinate(for: inlineLocalUV)
    let expected = SIMD2<Float>(0.5, Float(windowPoint.y / window.height))
    #expect(abs(largeTitleUV.x - expected.x) < 0.00001)
    #expect(abs(largeTitleUV.y - expected.y) < 0.00001)
    #expect(abs(inlineTitleUV.x - expected.x) < 0.00001)
    #expect(abs(inlineTitleUV.y - expected.y) < 0.00001)
}

@Test func mappingRejectsEmptyOrNonfiniteViewports() {
    #expect(SharedBackgroundUVMapping(
        windowBounds: CGRect(x: 0, y: 0, width: 0, height: 844),
        presenterRect: CGRect(x: 0, y: 0, width: 390, height: 844)
    ) == nil)
    #expect(SharedBackgroundUVMapping(
        windowBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
        presenterRect: CGRect(x: CGFloat.infinity, y: 0, width: 390, height: 844)
    ) == nil)
}

@Test @MainActor func geometryInvalidatesWhenWindowOriginChangesWithoutSizeOrUVChanges() throws {
    let windowBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
    let presenter = CGRect(x: 0, y: 100, width: 390, height: 744)
    let windowID = ObjectIdentifier(UIView())
    let first = try #require(SharedBackgroundPresentationGeometry(
        windowIdentity: windowID,
        windowRectOnScreen: CGRect(x: 0, y: 0, width: 390, height: 844),
        windowBounds: windowBounds,
        presenterRect: presenter,
        displayScale: 3,
        baseColor: SIMD4<Float>(0.1, 0.2, 0.3, 1)
    ))
    let moved = try #require(SharedBackgroundPresentationGeometry(
        windowIdentity: windowID,
        windowRectOnScreen: CGRect(x: 390, y: 0, width: 390, height: 844),
        windowBounds: windowBounds,
        presenterRect: presenter,
        displayScale: 3,
        baseColor: SIMD4<Float>(0.1, 0.2, 0.3, 1)
    ))

    #expect(first.mapping == moved.mapping)
    #expect(first != moved)
}

@Test @MainActor func geometryInvalidatesWhenResolvedBaseColorOrDisplayScaleChanges() throws {
    let windowID = ObjectIdentifier(UIView())
    let window = CGRect(x: 0, y: 0, width: 390, height: 844)
    func geometry(scale: CGFloat, color: SIMD4<Float>) throws -> SharedBackgroundPresentationGeometry {
        try #require(SharedBackgroundPresentationGeometry(
            windowIdentity: windowID,
            windowRectOnScreen: window,
            windowBounds: window,
            presenterRect: window,
            displayScale: scale,
            baseColor: color
        ))
    }
    let initial = try geometry(scale: 3, color: SIMD4<Float>(0.1, 0.2, 0.3, 1))

    #expect(initial != (try geometry(scale: 3, color: SIMD4<Float>(0.2, 0.2, 0.3, 1))))
    #expect(initial != (try geometry(scale: 2, color: SIMD4<Float>(0.1, 0.2, 0.3, 1))))
}
