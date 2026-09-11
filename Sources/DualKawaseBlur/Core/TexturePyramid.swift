import Metal

/// Immutable intermediate textures owned by one in-flight blur operation.
final class TexturePyramid {
    let textures: [MTLTexture]
    let layout: TexturePyramidLayout
    let pixelFormat: MTLPixelFormat

    init(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        configuration: BlurConfiguration
    ) throws {
        let layout: TexturePyramidLayout
        do {
            layout = try TexturePyramidLayout(
                width: width,
                height: height,
                configuration: configuration
            )
        } catch {
            throw DualKawaseBlurError.invalidConfiguration
        }

        guard pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb else {
            throw DualKawaseBlurError.unsupportedTexture
        }

        self.layout = layout
        self.pixelFormat = pixelFormat
        textures = try layout.levels.map { level in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: level.width,
                height: level.height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DualKawaseBlurError.textureAllocationFailed
            }
            return texture
        }
    }

    subscript(index: Int) -> MTLTexture {
        textures[index]
    }
}
