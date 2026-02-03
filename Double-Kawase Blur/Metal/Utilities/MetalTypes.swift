import Foundation
import simd

/// Uniforms passed to blur shaders
struct BlurUniforms {
    /// Half-pixel offset (0.5/width, 0.5/height) for current texture
    var halfpixel: SIMD2<Float>

    /// User-controlled offset multiplier (1.0-5.0)
    var offset: SIMD2<Float>

    init(textureWidth: Float, textureHeight: Float, offsetValue: Float) {
        self.halfpixel = SIMD2<Float>(0.5 / textureWidth, 0.5 / textureHeight)
        self.offset = SIMD2<Float>(offsetValue, offsetValue)
    }
}

/// Vertex structure for full-screen quad
struct Vertex {
    var position: SIMD3<Float>

    init(_ x: Float, _ y: Float, _ z: Float) {
        self.position = SIMD3<Float>(x, y, z)
    }
}
