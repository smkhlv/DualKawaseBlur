import UIKit
import Metal
import MetalKit
import CoreGraphics

/// Handles conversion between UIImage and Metal textures
class ImageTextureConverter {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader

    enum ConversionError: Error {
        case cgImageCreationFailed
        case textureCreationFailed
        case invalidTextureFormat
        case bufferCreationFailed
    }

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    /// Convert UIImage to MTLTexture
    func texture(from image: UIImage) throws -> MTLTexture {
        guard let cgImage = image.cgImage else {
            throw ConversionError.cgImageCreationFailed
        }

        // Load texture with sRGB color space for correct gamma handling
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .SRGB: NSNumber(value: true)
        ]

        do {
            return try textureLoader.newTexture(cgImage: cgImage, options: options)
        } catch {
            throw ConversionError.textureCreationFailed
        }
    }

    /// Convert MTLTexture to UIImage
    func image(from texture: MTLTexture) throws -> UIImage {
        // For private storage, need to blit to shared texture first
        // Convert from sRGB to linear during blit by using non-sRGB format
        let sharedTexture = try createSharedTexture(from: texture)

        // Extract bytes from texture
        let width = texture.width
        let height = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let imageByteCount = bytesPerRow * height

        var imageBytes = [UInt8](repeating: 0, count: imageByteCount)

        let region = MTLRegionMake2D(0, 0, width, height)
        sharedTexture.getBytes(&imageBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // Create CGImage from bytes with sRGB color space
        // Note: texture is in sRGB format, so bytes are already gamma-corrected
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmapContext = CGContext(
                data: &imageBytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let cgImage = bitmapContext.makeImage() else {
            throw ConversionError.cgImageCreationFailed
        }

        return UIImage(cgImage: cgImage)
    }

    /// Create shared-storage copy of texture for CPU access
    private func createSharedTexture(from texture: MTLTexture) throws -> MTLTexture {
        // If already shared, return as-is
        if texture.storageMode == .shared {
            return texture
        }

        // Create shared texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead

        guard let sharedTexture = device.makeTexture(descriptor: descriptor) else {
            throw ConversionError.textureCreationFailed
        }

        // Copy private texture to shared via blit
        guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw ConversionError.bufferCreationFailed
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: sharedTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return sharedTexture
    }
}
