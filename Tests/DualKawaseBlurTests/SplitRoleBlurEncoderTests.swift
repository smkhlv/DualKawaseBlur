import Metal
import Testing
@_spi(Benchmark) @testable import DualKawaseBlur

@Test func splitPlanForFiveLevels() {
    let plan = SplitRoleBlurEncoder.plan(levelCount: 5)
    #expect(plan == [
        .renderDownsample(from: -1, to: 0),
        .compute([
            .downsample(from: 0, to: 1), .downsample(from: 1, to: 2),
            .downsample(from: 2, to: 3), .downsample(from: 3, to: 4),
            .upsample(from: 4, to: 3), .upsample(from: 3, to: 2), .upsample(from: 2, to: 1),
        ]),
        .renderRestore(from: 1, to: 0),
        .renderFinal(from: 0),
    ])
    #expect(plan.filter { if case .compute = $0 { false } else { true } }.count == 3)
    if case .compute(let passes) = plan[1] { #expect(passes.count == 7) }
}

@Test func splitPlanForTwoLevels() {
    #expect(SplitRoleBlurEncoder.plan(levelCount: 2) == [
        .renderDownsample(from: -1, to: 0),
        .compute([.downsample(from: 0, to: 1)]),
        .renderRestore(from: 1, to: 0),
        .renderFinal(from: 0),
    ])
}

@Test func splitIntermediateRoles() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let candidate = try SplitRoleBlurEncoder(device: device, width: 37, height: 53,
        pixelFormat: .bgra8Unorm, configuration: BlurConfiguration(iterations: 3, offset: 5))
    let textures = candidate.intermediateTextures
    #expect(textures.count == 3)
    #expect(textures[0].usage == [.shaderRead, .renderTarget])
    for texture in textures.dropFirst() { #expect(texture.usage == [.shaderRead, .shaderWrite]) }
    for texture in textures { #expect(texture.storageMode == .private) }
}

@Test(arguments: [(8, 12, 2), (32, 48, 3), (37, 53, 3), (35, 48, 2)], [Float(0.25), 1, 5, 12])
func splitMatchesAllRenderRedistributed(size: (Int, Int, Int), offset: Float) async throws {
    let (width, height, iterations) = size
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let configuration = BlurConfiguration(iterations: iterations, offset: offset)
    let reference = try RedistributedAllRenderBlurEncoder(device: device, width: width, height: height,
        pixelFormat: .bgra8Unorm, configuration: configuration)
    let split = try SplitRoleBlurEncoder(device: device, width: width, height: height,
        pixelFormat: .bgra8Unorm, configuration: configuration)
    let source = try TestTexture.patterned(device: device, width: width, height: height)
    let expected = try TestTexture.empty(device: device, width: width, height: height, usage: .renderTarget)
    let first = try TestTexture.empty(device: device, width: width, height: height, usage: .renderTarget)
    let second = try TestTexture.empty(device: device, width: width, height: height, usage: .renderTarget)
    let buffer = try #require(queue.makeCommandBuffer())
    try reference.encode(source: source, destination: expected, into: buffer)
    try split.encode(source: source, destination: first, into: buffer)
    try split.encode(source: source, destination: second, into: buffer)
    #expect(await buffer.commitAndWaitForCompletion() == .completed)
    let expectedBytes = [UInt8](TestTexture.bytes(expected)), actualBytes = [UInt8](TestTexture.bytes(first))
    #expect(expectedBytes.count == actualBytes.count)
    let maxDifference = zip(expectedBytes, actualBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(maxDifference <= 1)
    #expect(TestTexture.bytes(first) == TestTexture.bytes(second))
}

@Test func splitOrdersQueuedResourceReuse() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let candidate = try SplitRoleBlurEncoder(device: device, width: 37, height: 53,
        pixelFormat: .bgra8Unorm, configuration: .init(iterations: 3, offset: 5))
    let sources = try (0..<12).map { try TestTexture.patterned(device: device, width: 37, height: 53, phase: $0) }
    let outputs = try sources.map { _ in try TestTexture.empty(device: device, width: 37, height: 53, usage: .renderTarget) }
    var buffers: [MTLCommandBuffer] = []
    for index in sources.indices {
        let buffer = try #require(queue.makeCommandBuffer())
        try candidate.encode(source: sources[index], destination: outputs[index], into: buffer)
        buffer.commit(); buffers.append(buffer)
    }
    // Same serial queue orders shared intermediate reuse; drain before reading any output.
    let drain = try #require(queue.makeCommandBuffer())
    #expect(await drain.commitAndWaitForCompletion() == .completed)
    for buffer in buffers { #expect(buffer.status == .completed) }
    for index in sources.indices {
        let repeatOutput = try TestTexture.empty(device: device, width: 37, height: 53, usage: .renderTarget)
        let buffer = try #require(queue.makeCommandBuffer())
        try candidate.encode(source: sources[index], destination: repeatOutput, into: buffer)
        #expect(await buffer.commitAndWaitForCompletion() == .completed)
        #expect(TestTexture.bytes(outputs[index]) == TestTexture.bytes(repeatOutput))
    }
}
