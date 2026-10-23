import Foundation
import Metal
import Testing
@_spi(Benchmark) @testable import DualKawaseBlur

/// The benchmark composite entry point is the presenters' composite: byte-equal to a direct internal
/// `encodeOpaqueComposite(.unit)` on the same source and target, from a full-size source and from a
/// half-size (level 0) one. The patterned source has non-opaque alpha, so the base color matters.
@Test(arguments: [(1179, 2556), (589, 1278), (37, 53)])
func benchmarkCompositeMatchesTheInternalUnitComposite(sourceSize: (Int, Int)) async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let (targetWidth, targetHeight) = (1179, 2556)
    let baseColor = SIMD4<Float>(0.25, 0.5, 0.75, 1)
    let source = try TestTexture.patterned(device: device, width: sourceSize.0, height: sourceSize.1)
    let target = try TestTexture.empty(device: device, width: targetWidth, height: targetHeight,
                                       usage: [.renderTarget])

    let spi = try BenchmarkOpaqueCompositeEncoder(device: device)
    var buffer = try #require(queue.makeCommandBuffer())
    try spi.encode(source: source, destination: target, baseColor: baseColor, into: buffer)
    #expect(await buffer.commitAndWaitForCompletion() == .completed)
    let candidate = TestTexture.bytes(target)

    let renderer = try DualKawaseBlurRenderer(context: MetalContext(device: device))
    buffer = try #require(queue.makeCommandBuffer())
    try renderer.encodeOpaqueComposite(source: source, destination: target, baseColor: baseColor,
                                       mapping: .unit, into: buffer)
    #expect(await buffer.commitAndWaitForCompletion() == .completed)
    let reference = TestTexture.bytes(target)

    #expect(BenchmarkOpaqueCompositeEncoder.mappingName == "unit")
    #expect(candidate.count == targetWidth * targetHeight * 4)
    #expect(candidate == reference)
    // Not vacuous: the composite wrote opaque pixels, not the zero-initialized target.
    #expect(stride(from: 3, to: candidate.count, by: 4).allSatisfy { candidate[$0] == 255 })
}
