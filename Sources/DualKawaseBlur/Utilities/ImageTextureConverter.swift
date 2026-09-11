import CoreImage
import Metal
import UIKit

struct PreparedImage: Sendable {
    let pixels: ImagePixels
    var width: Int { pixels.width }
    var height: Int { pixels.height }
    var scale: CGFloat { pixels.scale }
}

struct ImagePixels: Sendable {
    enum ColorSpace: Sendable, Equatable {
        case sRGB
        case displayP3

        var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
            }
        }
    }

    let bytes: Data
    let width: Int
    let height: Int
    let scale: CGFloat
    let colorSpace: ColorSpace
}

final class ImageTextureConverter: Sendable {
    enum ConversionError: Error, Sendable {
        case cgImageCreationFailed
        case textureCreationFailed
        case invalidTextureFormat
        case bufferCreationFailed
    }

    private let device: MTLDevice

    init(device: MTLDevice) { self.device = device }

    @MainActor
    func prepare(_ image: UIImage) throws -> PreparedImage {
        guard image.size.width > 0, image.size.height > 0, image.scale > 0 else {
            throw ConversionError.cgImageCreationFailed
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        format.preferredRange = .standard
        let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = normalized.cgImage else {
            throw ConversionError.cgImageCreationFailed
        }
        let colorSpace: ImagePixels.ColorSpace = image.cgImage?.colorSpace?.name == CGColorSpace.displayP3
            || image.ciImage?.colorSpace?.name == CGColorSpace.displayP3
            ? .displayP3
            : .sRGB
        return PreparedImage(pixels: ImagePixels(
            bytes: try Self.bgraBytes(from: cgImage, colorSpace: colorSpace.cgColorSpace),
            width: cgImage.width,
            height: cgImage.height,
            scale: image.scale,
            colorSpace: colorSpace
        ))
    }

    @MainActor
    func image(from pixels: ImagePixels) throws -> UIImage {
        UIImage(cgImage: try Self.makeCGImage(from: pixels), scale: pixels.scale, orientation: .up)
    }

    @MainActor
    func texture(from image: UIImage) throws -> MTLTexture {
        try texture(from: prepare(image))
    }

    func texture(from image: PreparedImage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: image.width,
            height: image.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ConversionError.textureCreationFailed
        }
        image.pixels.bytes.withUnsafeBytes { storage in
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height),
                mipmapLevel: 0,
                withBytes: storage.baseAddress!,
                bytesPerRow: image.width * 4
            )
        }
        return texture
    }

    func makeReadbackTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) throws -> MTLTexture {
        guard pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb else {
            throw ConversionError.invalidTextureFormat
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ConversionError.textureCreationFailed
        }
        return texture
    }

    func encodeReadback(from source: MTLTexture, to destination: MTLTexture, into commandBuffer: MTLCommandBuffer) throws {
        guard source.device === device, destination.device === device,
              commandBuffer.device === device, source.width == destination.width,
              source.height == destination.height, source.pixelFormat == destination.pixelFormat,
              let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw ConversionError.bufferCreationFailed
        }
        encoder.copy(
            from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: source.width, height: source.height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }

    func pixels(from texture: MTLTexture, metadata: PreparedImage) throws -> ImagePixels {
        guard texture.storageMode == .shared else { throw ConversionError.invalidTextureFormat }
        var bytes = Data(count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            texture.getBytes(
                storage.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
            )
        }
        return ImagePixels(
            bytes: bytes, width: texture.width, height: texture.height,
            scale: metadata.scale, colorSpace: metadata.pixels.colorSpace
        )
    }

    private static func bgraBytes(from image: CGImage, colorSpace: CGColorSpace) throws -> Data {
        var bytes = Data(count: image.width * image.height * 4)
        let succeeded = bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard succeeded else { throw ConversionError.cgImageCreationFailed }
        return bytes
    }

    @MainActor
    private static func makeCGImage(from pixels: ImagePixels) throws -> CGImage {
        guard let provider = CGDataProvider(data: pixels.bytes as CFData),
              let image = CGImage(
                width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: pixels.width * 4, space: pixels.colorSpace.cgColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { throw ConversionError.cgImageCreationFailed }
        return image
    }
}
