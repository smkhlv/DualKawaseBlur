import Testing
import Metal
@_spi(Benchmark) @testable import DualKawaseBlur

@Test func percentilesUseSortedNearestRank() {
    let values = [9.0, 1.0, 5.0, 3.0, 7.0]

    #expect(BenchmarkMath.percentile(values, 0.50) == 5.0)
    #expect(BenchmarkMath.percentile(values, 0.95) == 9.0)
}

@Test func impulseSecondMomentGrowsWithRadius() {
    let narrow: [Double] = [0, 1, 0]
    let wide: [Double] = [0.25, 0.5, 0.25]

    #expect(BenchmarkMath.secondMoment(wide) > BenchmarkMath.secondMoment(narrow))
}

@Test func normalizedRMSEIsZeroForIdenticalSamples() {
    let samples = [0.0, 0.25, 1.0]

    #expect(BenchmarkMath.normalizedRMSE(samples, samples) == 0)
}

@Test func normalizedRMSEUsesReferenceRange() {
    let reference = [0.0, 1.0]
    let candidate = [0.0, 0.0]

    #expect(abs(BenchmarkMath.normalizedRMSE(reference, candidate) - 0.707_106_78) < 0.000_001)
}

@Test func benchmarkEncoderReusesItsPreallocatedWorkspace() async throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let configuration = BlurConfiguration(iterations: 2, offset: 1)
    let encoder = try BenchmarkBlurEncoder(
        device: device,
        width: 16,
        height: 16,
        pixelFormat: .bgra8Unorm,
        configuration: configuration
    )
    let source = try TestTexture.impulse(device: device, width: 16, height: 16)
    let destination = try TestTexture.empty(device: device, width: 16, height: 16)

    for _ in 0..<2 {
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try encoder.encode(source: source, destination: destination, into: commandBuffer)
        #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
    }
}
