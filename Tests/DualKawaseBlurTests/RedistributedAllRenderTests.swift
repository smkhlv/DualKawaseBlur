import Metal
import Testing
@_spi(Benchmark) @testable import DualKawaseBlur

@Test func redistributedAllRenderIntermediateRoles() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let candidate = try RedistributedAllRenderBlurEncoder(device: device, width: 37, height: 53,
        pixelFormat: .bgra8Unorm, configuration: BlurConfiguration(iterations: 3, offset: 5))
    let textures = candidate.intermediateTextures
    #expect(textures.count == 3)
    #expect(Set(textures.map(ObjectIdentifier.init)).count == 3)
    for texture in textures {
        #expect(texture.storageMode == .private)
        #expect(texture.hazardTrackingMode == .tracked)
        #expect(texture.usage == [.shaderRead, .renderTarget])
    }
}

@Test func redistributedAllRenderIsDeterministic() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let (width, height) = (37, 53)
    let candidate = try RedistributedAllRenderBlurEncoder(device: device, width: width, height: height,
        pixelFormat: .bgra8Unorm, configuration: BlurConfiguration(iterations: 3, offset: 5))
    let source = try TestTexture.empty(device: device, width: width, height: height)
    let first = try TestTexture.empty(device: device, width: width, height: height, usage: .renderTarget)
    let second = try TestTexture.empty(device: device, width: width, height: height, usage: .renderTarget)
    for phase in 0..<3 {
        let bytes = (0..<(width * height * 4)).map { UInt8(($0 * 73 + $0 / 4 * 19 + phase * 37) % 256) }
        source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                       withBytes: bytes, bytesPerRow: width * 4)
        let buffer = try #require(queue.makeCommandBuffer())
        try candidate.encode(source: source, destination: first, into: buffer)
        try candidate.encode(source: source, destination: second, into: buffer)
        #expect(await buffer.commitAndWaitForCompletion() == .completed)
        #expect(TestTexture.bytes(first) == TestTexture.bytes(second))
    }
}

@Test func redistributedAllRenderPreservesConstantImage() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let (width, height) = (35, 48)
    let candidate = try RedistributedAllRenderBlurEncoder(device: device, width: width, height: height,
        pixelFormat: .bgra8Unorm, configuration: BlurConfiguration(iterations: 2, offset: 5))
    let source = try TestTexture.empty(device: device, width: width, height: height)
    let input: [UInt8] = [90, 140, 200, 255]
    let bytes = (0..<(width * height)).flatMap { _ in input }
    source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                   withBytes: bytes, bytesPerRow: width * 4)
    let output = try TestTexture.empty(device: device, width: width, height: height, usage: .renderTarget)
    let buffer = try #require(queue.makeCommandBuffer())
    try candidate.encode(source: source, destination: output, into: buffer)
    #expect(await buffer.commitAndWaitForCompletion() == .completed)
    for (index, value) in TestTexture.bytes(output).enumerated() {
        #expect(abs(Int(value) - Int(input[index % 4])) <= 1)
    }
}

@Test func redistributedAllRenderOrdersQueuedResourceReuse() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let candidate = try RedistributedAllRenderBlurEncoder(device: device, width: 37, height: 53,
        pixelFormat: .bgra8Unorm, configuration: .init(iterations: 3, offset: 5))
    let sources = try (0..<12).map { phase in
        let texture = try TestTexture.empty(device: device, width: 37, height: 53)
        let bytes = (0..<(37 * 53 * 4)).map { UInt8(($0 * 73 + phase * 17) % 256) }
        texture.replace(region: MTLRegionMake2D(0, 0, 37, 53), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: 37 * 4)
        return texture
    }
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
