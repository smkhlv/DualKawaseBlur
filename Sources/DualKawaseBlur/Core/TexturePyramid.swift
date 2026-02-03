import Metal
import CoreGraphics

/// Pyramid of textures with decreasing resolutions for blur algorithm
class TexturePyramid {
    private(set) var textures: [MTLTexture] = []
    private let device: MTLDevice

    private(set) var baseSize: CGSize = .zero
    private(set) var iterations: Int = 0

    enum PyramidError: Error {
        case invalidIterations
        case textureCreationFailed
        case invalidSize
    }

    init(device: MTLDevice) {
        self.device = device
    }

    /// Create or recreate pyramid with new parameters
    /// - Parameters:
    ///   - size: Base texture size (level 0)
    ///   - iterations: Number of blur iterations (1-5), determines pyramid depth
    func createPyramid(size: CGSize, iterations: Int) throws {
        guard iterations >= 1 && iterations <= 5 else {
            throw PyramidError.invalidIterations
        }

        guard size.width > 0 && size.height > 0 else {
            throw PyramidError.invalidSize
        }

        // Only recreate if parameters changed
        if self.baseSize == size && self.iterations == iterations {
            return
        }

        self.baseSize = size
        self.iterations = iterations

        // Create pyramid: level 0 = original size, each level = previous / 2
        // Total levels = iterations + 1 (0 to iterations inclusive)
        var newTextures: [MTLTexture] = []
        newTextures.reserveCapacity(iterations + 1)

        for i in 0...iterations {
            let levelSize = CGSize(
                width: size.width / pow(2.0, Double(i)),
                height: size.height / pow(2.0, Double(i))
            )

            guard let texture = createTexture(size: levelSize) else {
                throw PyramidError.textureCreationFailed
            }

            newTextures.append(texture)
        }

        self.textures = newTextures
    }

    /// Create a single texture with appropriate configuration
    private func createTexture(size: CGSize) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,  // sRGB format for correct color handling
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )

        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private  // GPU-only for performance

        return device.makeTexture(descriptor: descriptor)
    }

    /// Access texture at specific pyramid level
    subscript(index: Int) -> MTLTexture {
        return textures[index]
    }

    /// Check if pyramid needs recreation for given parameters
    func needsRecreation(size: CGSize, iterations: Int) -> Bool {
        return self.baseSize != size || self.iterations != iterations
    }

    /// Clear all textures (for memory management)
    func clear() {
        textures.removeAll()
        baseSize = .zero
        iterations = 0
    }
}
