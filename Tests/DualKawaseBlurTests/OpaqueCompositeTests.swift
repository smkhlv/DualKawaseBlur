import Metal
import Testing
@testable import DualKawaseBlur

@Test func opaqueCompositeReadsUploadedHalfAlphaTexture() throws {
    let sourcePixel: [UInt8] = [26, 102, 51, 128]
    let result = try composite(sourcePixel: sourcePixel, baseColor: SIMD4<Float>(0.8, 0.2, 0.6, 1))
    #expect(result.uploadedSource == Array(repeating: sourcePixel, count: 16).flatMap { $0 })
}

@Test func opaqueCompositeUsesBaseColorForTransparentSource() throws {
    let result = try composite(sourcePixel: [0, 0, 0, 0], baseColor: SIMD4<Float>(0.8, 0.2, 0.6, 1))
    for pixelIndex in 0..<16 {
        let offset = pixelIndex * 4
        let pixel = Array(result.output[offset..<(offset + 4)])
        #expect(pixel == [153, 51, 204, 255], "BGRA pixel: \(pixel)")
    }
}

@Test func opaqueCompositePreservesRGBReferenceAndWritesOpaqueEdges() throws {
    let result = try composite(sourcePixel: [26, 102, 51, 128], baseColor: SIMD4<Float>(0.8, 0.2, 0.6, 1))
    for pixelIndex in 0..<16 {
        let offset = pixelIndex * 4
        let pixel = Array(result.output[offset..<(offset + 4)])
        #expect(pixel == [102, 127, 153, 255], "BGRA pixel: \(pixel)")
    }
}

@Test func opaqueCompositeMapsNonzeroCanonicalWindowOriginAndScale() throws {
    let sourceWidth = 8
    let sourceHeight = 8
    let quadrantColors: [[UInt8]] = [
        [10, 20, 30, 255], [40, 50, 60, 255],
        [70, 80, 90, 255], [120, 130, 140, 255]
    ]
    var pixels: [UInt8] = []
    for y in 0..<sourceHeight {
        for x in 0..<sourceWidth {
            let quadrant = (y >= sourceHeight / 2 ? 2 : 0) + (x >= sourceWidth / 2 ? 1 : 0)
            pixels.append(contentsOf: quadrantColors[quadrant])
        }
    }
    let mapping = SharedBackgroundUVMapping(
        origin: SIMD2<Float>(0.5, 0.5),
        scale: SIMD2<Float>(0.5, 0.5)
    )
    let result = try composite(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        sourcePixels: pixels,
        baseColor: SIMD4<Float>(0.1, 0.2, 0.3, 1),
        mapping: mapping
    )
    for pixelIndex in 0..<16 {
        let offset = pixelIndex * 4
        let pixel = Array(result.output[offset..<(offset + 4)])
        #expect(pixel == [120, 130, 140, 255], "BGRA pixel: \(pixel)")
    }
}

private func composite(
    sourcePixel: [UInt8],
    baseColor: SIMD4<Float>,
    mapping: SharedBackgroundUVMapping = .unit
) throws -> (uploadedSource: [UInt8], output: [UInt8]) {
    try composite(
        sourceWidth: 4,
        sourceHeight: 4,
        sourcePixels: Array(repeating: sourcePixel, count: 16).flatMap { $0 },
        baseColor: baseColor,
        mapping: mapping
    )
}

private func composite(
    sourceWidth: Int,
    sourceHeight: Int,
    sourcePixels: [UInt8],
    baseColor: SIMD4<Float>,
    mapping: SharedBackgroundUVMapping
) throws -> (uploadedSource: [UInt8], output: [UInt8]) {
    guard let device = MTLCreateSystemDefaultDevice() else {
        Issue.record("Metal is unavailable in this test environment.")
        throw CompositeTestError.metalUnavailable
    }
    let context = try MetalContext(device: device)
    let renderer = try DualKawaseBlurRenderer(context: context)
    let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: sourceWidth, height: sourceHeight, mipmapped: false
    )
    sourceDescriptor.storageMode = .shared
    sourceDescriptor.usage = [.shaderRead]
    let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false
    )
    outputDescriptor.storageMode = .shared
    outputDescriptor.usage = [.renderTarget, .shaderRead]
    guard let source = device.makeTexture(descriptor: sourceDescriptor),
          let output = device.makeTexture(descriptor: outputDescriptor) else {
        throw CompositeTestError.textureUnavailable
    }

    sourcePixels.withUnsafeBytes {
        source.replace(region: MTLRegionMake2D(0, 0, sourceWidth, sourceHeight), mipmapLevel: 0,
                       withBytes: $0.baseAddress!, bytesPerRow: sourceWidth * 4)
    }
    var uploadedSource = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
    uploadedSource.withUnsafeMutableBytes {
        source.getBytes($0.baseAddress!, bytesPerRow: sourceWidth * 4,
                        from: MTLRegionMake2D(0, 0, sourceWidth, sourceHeight), mipmapLevel: 0)
    }

    guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
        throw CompositeTestError.commandBufferUnavailable
    }
    try renderer.encodeOpaqueComposite(
        source: source,
        destination: output,
        baseColor: baseColor,
        mapping: mapping,
        into: commandBuffer
    )
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    #expect(commandBuffer.status == .completed)

    var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
    bytes.withUnsafeMutableBytes {
        output.getBytes($0.baseAddress!, bytesPerRow: 16,
                        from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
    }
    return (uploadedSource, bytes)
}

private enum CompositeTestError: Error {
    case metalUnavailable
    case textureUnavailable
    case commandBufferUnavailable
}
