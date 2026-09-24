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

@Test func normalizedLumaRMSEIgnoresAlphaAndUsesBGRAOrder() {
    let reference = Data([0, 0, 0, 0, 255, 255, 255, 255])
    let candidate = Data([0, 0, 0, 255, 0, 0, 0, 0])

    #expect(abs(BenchmarkMath.normalizedLumaRMSE(referenceBGRA: reference, candidateBGRA: candidate) - 0.707_106_78) < 0.000_001)
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

@Test func computeProfilesChangeOnlyOneOptimizationVariable() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let configuration = BlurConfiguration(iterations: 5, offset: 2)

    let faithful = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: 128,
        height: 64,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .faithful
    )
    let momentMatched = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: 128,
        height: 64,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .momentMatchedFinal
    )
    let triangular = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: 128,
        height: 64,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .triangularMomentMatchedFinal
    )
    let allLevelMomentMatched = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: 128,
        height: 64,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .allLevelMomentMatched
    )
    let fourTapDownsample = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: 128,
        height: 64,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .fourTapDownsampleAllLevelMomentMatched
    )

    #expect((faithful.downsampleTapCount, faithful.intermediateUpsampleTapCount, faithful.finalUpsampleTapCount) == (5, 8, 8))
    #expect((momentMatched.downsampleTapCount, momentMatched.intermediateUpsampleTapCount, momentMatched.finalUpsampleTapCount) == (5, 8, 4))
    #expect((triangular.downsampleTapCount, triangular.intermediateUpsampleTapCount, triangular.finalUpsampleTapCount) == (5, 8, 3))
    #expect((allLevelMomentMatched.downsampleTapCount, allLevelMomentMatched.intermediateUpsampleTapCount, allLevelMomentMatched.finalUpsampleTapCount) == (5, 4, 3))
    #expect((fourTapDownsample.downsampleTapCount, fourTapDownsample.intermediateUpsampleTapCount, fourTapDownsample.finalUpsampleTapCount) == (4, 4, 3))
    #expect([faithful, momentMatched, triangular, allLevelMomentMatched, fourTapDownsample].allSatisfy { $0.reductionLevelCount == 5 })
}

@Test func everyComputeProfileCompletesWithPreallocatedTextures() async throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let source = try TestTexture.impulse(device: device, width: 64, height: 64)
    let destination = try TestTexture.empty(
        device: device,
        width: 64,
        height: 64,
        usage: [.shaderRead, .shaderWrite]
    )

    for mode in [
        ComputeDualKawaseBlurEncoder.Mode.faithful,
        .momentMatchedFinal,
        .triangularMomentMatchedFinal,
        .allLevelMomentMatched,
        .fourTapDownsampleAllLevelMomentMatched
    ] {
        let encoder = try ComputeDualKawaseBlurEncoder(
            device: device,
            width: 64,
            height: 64,
            pixelFormat: .bgra8Unorm,
            configuration: .init(iterations: 5, offset: 2),
            mode: mode
        )
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try encoder.encode(source: source, destination: destination, into: commandBuffer)
        #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
    }
}

@Test func threadgroupCandidatesAreValidForEveryComputePipeline() async throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let configuration = BlurConfiguration(iterations: 5, offset: 2)
    let probe = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: 128,
        height: 64,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .allLevelMomentMatched
    )
    #expect(probe.threadgroupCandidates.contains(probe.threadgroupSize))
    #expect(Set(probe.threadgroupCandidates).count == probe.threadgroupCandidates.count)

    let source = try TestTexture.impulse(device: device, width: 128, height: 64)
    let destination = try TestTexture.empty(
        device: device,
        width: 128,
        height: 64,
        usage: [.shaderRead, .shaderWrite]
    )
    for size in probe.threadgroupCandidates {
        let encoder = try ComputeDualKawaseBlurEncoder(
            device: device,
            width: 128,
            height: 64,
            pixelFormat: .bgra8Unorm,
            configuration: configuration,
            mode: .allLevelMomentMatched,
            threadgroupSize: size
        )
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try encoder.encode(source: source, destination: destination, into: commandBuffer)
        #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
    }
}

@Test func allLevelMomentMatchingStaysCloseToThreeTapBaseline() async throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let width = 128
    let height = 64
    let configuration = BlurConfiguration(iterations: 5, offset: 2)
    let source = try TestTexture.impulse(device: device, width: width, height: height)
    let baselineDestination = try TestTexture.empty(
        device: device,
        width: width,
        height: height,
        usage: [.shaderRead, .shaderWrite]
    )
    let candidateDestination = try TestTexture.empty(
        device: device,
        width: width,
        height: height,
        usage: [.shaderRead, .shaderWrite]
    )
    let baseline = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: width,
        height: height,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .triangularMomentMatchedFinal
    )
    let candidate = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: width,
        height: height,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .allLevelMomentMatched
    )

    let baselineCommandBuffer = try #require(queue.makeCommandBuffer())
    try baseline.encode(source: source, destination: baselineDestination, into: baselineCommandBuffer)
    #expect(await baselineCommandBuffer.commitAndWaitForCompletion() == .completed)

    let candidateCommandBuffer = try #require(queue.makeCommandBuffer())
    try candidate.encode(source: source, destination: candidateDestination, into: candidateCommandBuffer)
    #expect(await candidateCommandBuffer.commitAndWaitForCompletion() == .completed)

    let error = BenchmarkMath.normalizedLumaRMSE(
        referenceBGRA: TestTexture.bytes(baselineDestination),
        candidateBGRA: TestTexture.bytes(candidateDestination)
    )
    #expect(error < 0.01, "All-level versus final-only moment-matched NRMSE: \(error)")
}

@Test func fourTapDownsampleStaysCloseToFiveTapAllLevelBaseline() async throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let width = 128
    let height = 64
    let configuration = BlurConfiguration(iterations: 5, offset: 2)
    let source = try TestTexture.impulse(device: device, width: width, height: height)
    let baselineDestination = try TestTexture.empty(
        device: device,
        width: width,
        height: height,
        usage: [.shaderRead, .shaderWrite]
    )
    let candidateDestination = try TestTexture.empty(
        device: device,
        width: width,
        height: height,
        usage: [.shaderRead, .shaderWrite]
    )
    let baseline = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: width,
        height: height,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .allLevelMomentMatched
    )
    let candidate = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: width,
        height: height,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .fourTapDownsampleAllLevelMomentMatched,
        threadgroupSize: baseline.threadgroupSize
    )

    let baselineCommandBuffer = try #require(queue.makeCommandBuffer())
    try baseline.encode(source: source, destination: baselineDestination, into: baselineCommandBuffer)
    #expect(await baselineCommandBuffer.commitAndWaitForCompletion() == .completed)

    let candidateCommandBuffer = try #require(queue.makeCommandBuffer())
    try candidate.encode(source: source, destination: candidateDestination, into: candidateCommandBuffer)
    #expect(await candidateCommandBuffer.commitAndWaitForCompletion() == .completed)

    let error = BenchmarkMath.normalizedLumaRMSE(
        referenceBGRA: TestTexture.bytes(baselineDestination),
        candidateBGRA: TestTexture.bytes(candidateDestination)
    )
    #expect(error < 0.01, "Four-tap downsample versus five-tap all-level NRMSE: \(error)")
}

@Test func triangularUpsampleStaysCloseToFourTapMomentMatchedOutput() async throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let width = 128
    let height = 64
    let configuration = BlurConfiguration(iterations: 5, offset: 2)
    let source = try TestTexture.impulse(device: device, width: width, height: height)
    let momentMatchedDestination = try TestTexture.empty(
        device: device,
        width: width,
        height: height,
        usage: [.shaderRead, .shaderWrite]
    )
    let triangularDestination = try TestTexture.empty(
        device: device,
        width: width,
        height: height,
        usage: [.shaderRead, .shaderWrite]
    )
    let momentMatched = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: width,
        height: height,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .momentMatchedFinal
    )
    let triangular = try ComputeDualKawaseBlurEncoder(
        device: device,
        width: width,
        height: height,
        pixelFormat: .bgra8Unorm,
        configuration: configuration,
        mode: .triangularMomentMatchedFinal
    )

    let momentMatchedCommandBuffer = try #require(queue.makeCommandBuffer())
    try momentMatched.encode(
        source: source,
        destination: momentMatchedDestination,
        into: momentMatchedCommandBuffer
    )
    #expect(await momentMatchedCommandBuffer.commitAndWaitForCompletion() == .completed)

    let triangularCommandBuffer = try #require(queue.makeCommandBuffer())
    try triangular.encode(
        source: source,
        destination: triangularDestination,
        into: triangularCommandBuffer
    )
    #expect(await triangularCommandBuffer.commitAndWaitForCompletion() == .completed)

    let error = BenchmarkMath.normalizedLumaRMSE(
        referenceBGRA: TestTexture.bytes(momentMatchedDestination),
        candidateBGRA: TestTexture.bytes(triangularDestination)
    )
    #expect(error < 0.01, "Three-tap versus four-tap NRMSE: \(error)")
}

@Test func fastDualEncoderCompletesWithPreallocatedReductionTextures() async throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let encoder = try FastDualKawaseBlurEncoder(
        device: device,
        width: 32,
        height: 32,
        pixelFormat: .bgra8Unorm,
        configuration: .init(iterations: 5, offset: 1.1)
    )
    let source = try TestTexture.impulse(device: device, width: 32, height: 32)
    let destination = try TestTexture.empty(device: device, width: 32, height: 32)

    for _ in 0..<2 {
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try encoder.encode(source: source, destination: destination, into: commandBuffer)
        #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
    }
}

@Test func reducedResolutionMPSEncoderCompletesWithPreallocatedTextures() async throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let encoder = try ReducedResolutionMPSGaussianEncoder(
        device: device,
        width: 32,
        height: 32,
        pixelFormat: .bgra8Unorm,
        sigma: 12,
        reductionOffset: 1.1,
        reductionLevelCount: 2
    )
    let source = try TestTexture.impulse(device: device, width: 32, height: 32)
    let destination = try TestTexture.empty(device: device, width: 32, height: 32)

    for _ in 0..<2 {
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try encoder.encode(source: source, destination: destination, into: commandBuffer)
        #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
    }
}
