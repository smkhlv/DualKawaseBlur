import Metal
import Testing
import UIKit
@testable import DualKawaseBlur

@MainActor
@Test func preparedImageNormalizesVisualOrientationAndPreservesScale() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let source = TestImage.asymmetricUIImage(scale: 3, orientation: .right)
    let converter = ImageTextureConverter(device: device)

    let prepared = try converter.prepare(source)

    #expect(prepared.scale == 3)
    #expect(prepared.width == Int(source.size.width * source.scale))
    #expect(prepared.height == Int(source.size.height * source.scale))
    let normalized = try converter.image(from: prepared.pixels)
    #expect(normalized.scale == 3)
    #expect(normalized.imageOrientation == .up)
    #expect(normalized.size == source.size)
    #expect(try rgba(at: CGPoint(x: 1, y: 1), in: normalized).blue > 200)
    #expect(try rgba(at: CGPoint(x: 6, y: 1), in: normalized).red > 200)
}

@MainActor
@Test func preparedImageAcceptsCIBackedInput() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let ciImage = CIImage(color: .cyan).cropped(to: CGRect(x: 0, y: 0, width: 12, height: 7))
    let source = UIImage(ciImage: ciImage, scale: 2, orientation: .up)
    let converter = ImageTextureConverter(device: device)

    let prepared = try converter.prepare(source)

    #expect(prepared.width == 12)
    #expect(prepared.height == 7)
    #expect(prepared.scale == 2)
}

@MainActor
@Test func preparedAndReconstructedImageRetainDisplayP3Descriptor() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let converter = ImageTextureConverter(device: device)

    let prepared = try converter.prepare(TestImage.displayP3UIImage())
    let result = try converter.image(from: prepared.pixels)

    #expect(prepared.pixels.colorSpace == .displayP3)
    #expect(result.cgImage?.colorSpace?.name == CGColorSpace.displayP3)
}

@MainActor
private func rgba(at point: CGPoint, in image: UIImage) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let cgImage = try #require(image.cgImage)
    let x = min(max(Int(point.x * image.scale), 0), cgImage.width - 1)
    let y = min(max(Int(point.y * image.scale), 0), cgImage.height - 1)
    var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(
        data: &bytes,
        width: cgImage.width,
        height: cgImage.height,
        bitsPerComponent: 8,
        bytesPerRow: cgImage.width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    let index = (y * cgImage.width + x) * 4
    return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3])
}
