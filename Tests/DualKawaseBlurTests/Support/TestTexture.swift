import Metal
@testable import DualKawaseBlur

enum TestTexture {
    static func impulse(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
    ) throws -> MTLTexture {
        let texture = try empty(
            device: device,
            width: width,
            height: height,
            pixelFormat: pixelFormat
        )
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let centerPixelIndex = ((height / 2) * width + width / 2) * 4
        bytes.replaceSubrange(centerPixelIndex..<(centerPixelIndex + 4), with: [255, 255, 255, 255])
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: width * 4
        )
        return texture
    }

    static func empty(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        usage: MTLTextureUsage = [.renderTarget, .shaderRead]
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw DualKawaseBlurError.textureAllocationFailed
        }
        return texture
    }

    static func nonZeroPixelCount(_ texture: MTLTexture) throws -> Int {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) { count, index in
            if bytes[index..<(index + 4)].contains(where: { $0 != 0 }) {
                count += 1
            }
        }
    }
}
