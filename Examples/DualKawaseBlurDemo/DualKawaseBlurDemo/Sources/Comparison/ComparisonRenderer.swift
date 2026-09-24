import Metal
import MetalPerformanceShaders
import UIKit
@_spi(Benchmark) import DualKawaseBlur

/// Demo-only readback for visual comparison. This is not a timing benchmark.
@MainActor
final class ComparisonRenderer {
    struct Output {
        let sourcePixels: Data
        let original: UIImage
        let dual: UIImage
        let triangularMomentMatchedDual: UIImage
        let allLevelMomentMatchedDual: UIImage
        let fourTapDownsampleDual: UIImage
        let gaussian: UIImage
    }

    enum RenderError: LocalizedError {
        case unavailable, allocation, imageConversion, gpuFailure

        var errorDescription: String? {
            switch self {
            case .unavailable: "Metal is unavailable on this device."
            case .allocation: "Unable to allocate comparison textures."
            case .imageConversion: "Unable to prepare the selected image."
            case .gpuFailure: "The GPU could not finish the comparison."
            }
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let engine: DualKawaseBlurEngine
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw RenderError.unavailable }
        self.device = device
        self.queue = queue
        engine = try DualKawaseBlurEngine(device: device)
    }

    func render(image: UIImage, request: ComparisonRequest) async throws -> Output {
        try Task.checkCancellation()
        let width = request.width, height = request.height
        let input = try sourceBytes(image: image, width: width, height: height)
        let source = try texture(width: width, height: height, usage: .shaderRead)
        let dual = try texture(width: width, height: height, usage: [.renderTarget, .shaderRead])
        let triangularMomentMatchedDual = try texture(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        let allLevelMomentMatchedDual = try texture(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        let fourTapDownsampleDual = try texture(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        let gaussian = try texture(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        input.withUnsafeBytes { storage in
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: storage.baseAddress!, bytesPerRow: width * 4)
        }
        guard let buffer = queue.makeCommandBuffer() else { throw RenderError.allocation }
        try engine.encode(source: source, destination: dual,
                          configuration: .init(iterations: request.iterations, offset: request.offset),
                          into: buffer)
        let triangularMomentMatchedDualEncoder = try ComputeDualKawaseBlurEncoder(
            device: device, width: width, height: height, pixelFormat: .bgra8Unorm,
            configuration: .init(iterations: request.iterations, offset: request.offset), mode: .triangularMomentMatchedFinal
        )
        try triangularMomentMatchedDualEncoder.encode(
            source: source,
            destination: triangularMomentMatchedDual,
            into: buffer
        )
        let allLevelMomentMatchedDualEncoder = try ComputeDualKawaseBlurEncoder(
            device: device, width: width, height: height, pixelFormat: .bgra8Unorm,
            configuration: .init(iterations: request.iterations, offset: request.offset), mode: .allLevelMomentMatched
        )
        try allLevelMomentMatchedDualEncoder.encode(
            source: source,
            destination: allLevelMomentMatchedDual,
            into: buffer
        )
        let fourTapDownsampleDualEncoder = try ComputeDualKawaseBlurEncoder(
            device: device,
            width: width,
            height: height,
            pixelFormat: .bgra8Unorm,
            configuration: .init(iterations: request.iterations, offset: request.offset),
            mode: .fourTapDownsampleAllLevelMomentMatched
        )
        try fourTapDownsampleDualEncoder.encode(
            source: source,
            destination: fourTapDownsampleDual,
            into: buffer
        )
        let kernel = MPSImageGaussianBlur(device: device, sigma: request.sigma)
        kernel.edgeMode = .clamp
        kernel.encode(commandBuffer: buffer, sourceTexture: source, destinationTexture: gaussian)
        // Keep all resources alive until actual GPU completion, even if the UI task is cancelled.
        let succeeded = await withCheckedContinuation { continuation in
            buffer.addCompletedHandler { completed in
                continuation.resume(returning: completed.status == .completed)
            }
            buffer.commit()
        }
        guard succeeded else { throw RenderError.gpuFailure }
        try Task.checkCancellation()
        return try Output(
            sourcePixels: input,
            original: makeImage(bytes: input, width: width, height: height),
            dual: readImage(dual),
            triangularMomentMatchedDual: readImage(triangularMomentMatchedDual),
            allLevelMomentMatchedDual: readImage(allLevelMomentMatchedDual),
            fourTapDownsampleDual: readImage(fourTapDownsampleDual),
            gaussian: readImage(gaussian)
        )
    }

    private func texture(width: Int, height: Int, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = usage
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocation }
        return texture
    }

    private func sourceBytes(image: UIImage, width: Int, height: Int) throws -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        // Normalize orientation and use one aspect-filled crop for all three panels.
        let cropped = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - drawSize.width) / 2,
                                  y: (size.height - drawSize.height) / 2,
                                  width: drawSize.width, height: drawSize.height))
        }
        guard let cgImage = cropped.cgImage else { throw RenderError.imageConversion }
        var bytes = Data(count: width * height * 4)
        let converted = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: Self.bitmapInfo.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            return true
        }
        guard converted else { throw RenderError.imageConversion }
        return bytes
    }

    private static var bitmapInfo: CGBitmapInfo {
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little)
    }

    private func readImage(_ texture: MTLTexture) throws -> UIImage {
        var bytes = Data(count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            texture.getBytes(storage.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return try makeImage(bytes: bytes, width: texture.width, height: texture.height)
    }

    private func makeImage(bytes: Data, width: Int, height: Int) throws -> UIImage {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colorSpace, bitmapInfo: Self.bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { throw RenderError.imageConversion }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }
}
