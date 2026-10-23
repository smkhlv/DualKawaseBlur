import Metal
import Testing
@_spi(Benchmark) @testable import DualKawaseBlur

#if targetEnvironment(simulator)
// The simulator SDK ships stub MTL4 headers, so the Metal 4 encoder is not compiled here.
@Test func metal4SplitMatchesClassicSplit() {
    recordMetal4Skipped("iOS Simulator SDK has no Metal 4")
}

@Test func metal4SplitOrdersQueuedResourceReuse() {
    recordMetal4Skipped("iOS Simulator SDK has no Metal 4")
}
#else
@available(iOS 26.0, macOS 26.0, *)
@Test(arguments: [(8, 12, 2), (32, 48, 3), (37, 53, 3), (35, 48, 2)], [Float(0.25), 1, 5, 12])
func metal4SplitMatchesClassicSplit(size: (Int, Int, Int), offset: Float) async throws {
    guard let device = try metal4Device() else { return }
    let (width, height, iterations) = size
    let configuration = BlurConfiguration(iterations: iterations, offset: offset)
    let classic = try SplitRoleBlurEncoder(device: device, width: width, height: height,
        pixelFormat: .bgra8Unorm, configuration: configuration)
    let candidate = try Metal4SplitRoleBlurEncoder(device: device, width: width, height: height,
        pixelFormat: .bgra8Unorm, configuration: configuration)
    let source = try TestTexture.patterned(device: device, width: width, height: height)
    let expected = try await classicSplit(classic, source: source, device: device)
    let first = try TestTexture.empty(device: device, width: width, height: height, usage: .renderTarget)
    let second = try TestTexture.empty(device: device, width: width, height: height, usage: .renderTarget)
    let runner = try Metal4Runner(device: device,
        residencySet: candidate.makeResidencySet(including: [source, first, second]), inFlight: 1)
    let completion = try runner.commit(slot: 0) { buffer in
        try candidate.encode(source: source, destination: first, into: buffer)
        try candidate.encode(source: source, destination: second, into: buffer)
    }
    #expect(await completion.succeeded())
    #expect(TestTexture.bytes(first) == TestTexture.bytes(expected))
    #expect(TestTexture.bytes(second) == TestTexture.bytes(expected))
}

@available(iOS 26.0, macOS 26.0, *)
@Test func metal4SplitOrdersQueuedResourceReuse() async throws {
    guard let device = try metal4Device() else { return }
    let classic = try SplitRoleBlurEncoder(device: device, width: 37, height: 53,
        pixelFormat: .bgra8Unorm, configuration: .init(iterations: 3, offset: 5))
    let candidate = try Metal4SplitRoleBlurEncoder(device: device, width: 37, height: 53,
        pixelFormat: .bgra8Unorm, configuration: .init(iterations: 3, offset: 5))
    let sources = try (0..<12).map { try TestTexture.patterned(device: device, width: 37, height: 53, phase: $0) }
    let outputs = try sources.map { _ in try TestTexture.empty(device: device, width: 37, height: 53, usage: .renderTarget) }
    let runner = try Metal4Runner(device: device,
        residencySet: candidate.makeResidencySet(including: sources + outputs), inFlight: 3)
    // Three command buffers in flight share the intermediates; an allocator is reused only after its feedback.
    var pending: [Metal4Completion?] = Array(repeating: nil, count: 3)
    var succeeded: [Bool] = []
    for index in sources.indices {
        let slot = index % 3
        if let previous = pending[slot] { succeeded.append(await previous.succeeded()) }
        pending[slot] = try runner.commit(slot: slot) { buffer in
            try candidate.encode(source: sources[index], destination: outputs[index], into: buffer)
        }
    }
    for completion in pending.compactMap({ $0 }) { succeeded.append(await completion.succeeded()) }
    #expect(succeeded == Array(repeating: true, count: 12))
    for index in sources.indices {
        let expected = try await classicSplit(classic, source: sources[index], device: device)
        #expect(TestTexture.bytes(outputs[index]) == TestTexture.bytes(expected))
    }
}

/// Returns nil (with a known issue) where `.metal4` is unsupported, so the suite still runs there.
@available(iOS 26.0, macOS 26.0, *)
private func metal4Device() throws -> MTLDevice? {
    let device = try #require(MTLCreateSystemDefaultDevice())
    guard device.supportsFamily(.metal4) else {
        recordMetal4Skipped("MTLGPUFamily.metal4 unsupported on \(device.name)")
        return nil
    }
    return device
}

/// Serial classic split reference on its own queue.
private func classicSplit(_ classic: SplitRoleBlurEncoder, source: MTLTexture,
                          device: MTLDevice) async throws -> MTLTexture {
    let output = try TestTexture.empty(device: device, width: source.width, height: source.height,
                                       usage: .renderTarget)
    let queue = try #require(device.makeCommandQueue())
    let buffer = try #require(queue.makeCommandBuffer())
    try classic.encode(source: source, destination: output, into: buffer)
    #expect(await buffer.commitAndWaitForCompletion() == .completed)
    return output
}

/// One `MTL4CommandQueue` with the residency set attached once and one allocator per in-flight buffer.
@available(iOS 26.0, macOS 26.0, *)
private struct Metal4Runner {
    let device: MTLDevice
    let queue: MTL4CommandQueue
    let allocators: [MTL4CommandAllocator]

    init(device: MTLDevice, residencySet: MTLResidencySet, inFlight: Int) throws {
        self.device = device
        queue = try #require(device.makeMTL4CommandQueue())
        queue.addResidencySet(residencySet)
        allocators = try (0..<inFlight).map { _ in try #require(device.makeCommandAllocator()) }
    }

    /// Encodes on `slot`'s allocator (its previous buffer must have completed) and commits.
    func commit(slot: Int, encode: (MTL4CommandBuffer) throws -> Void) throws -> Metal4Completion {
        let allocator = allocators[slot]
        allocator.reset()
        let buffer = try #require(device.makeCommandBuffer())
        buffer.beginCommandBuffer(allocator: allocator)
        try encode(buffer)
        buffer.endCommandBuffer()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { feedback in
            continuation.yield(feedback.error == nil)
            continuation.finish()
        }
        queue.commit([buffer], options: options)
        return Metal4Completion(stream: stream)
    }
}

/// Resolves once the queue's commit feedback arrives (after the GPU finishes the buffer).
private struct Metal4Completion {
    let stream: AsyncStream<Bool>

    func succeeded() async -> Bool {
        for await succeeded in stream { return succeeded }
        return false
    }
}
#endif

private func recordMetal4Skipped(_ reason: String) {
    withKnownIssue("Metal 4 assertions did not run") { Issue.record(Comment(rawValue: reason)) }
}
