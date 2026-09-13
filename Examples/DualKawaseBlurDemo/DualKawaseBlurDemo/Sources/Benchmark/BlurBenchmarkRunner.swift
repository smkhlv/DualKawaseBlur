import Metal
import MetalPerformanceShaders
import QuartzCore
@_spi(Benchmark) import DualKawaseBlur

@MainActor
final class BlurBenchmarkRunner {
    struct Samples: Sendable {
        var cpuEncodeMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var endToEndMilliseconds: [Double] = []
    }

    struct Output: Sendable {
        let dualKawase: Samples
        let mpsGaussian: Samples
        let warmUpIterations: Int
        let measuredIterations: Int
    }

    enum RunnerError: Error { case metalUnavailable, allocationFailed, commandFailed }

    private struct CompletedTiming: Sendable {
        let gpuMilliseconds: Double
        let completed: Bool
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw RunnerError.metalUnavailable
        }
        self.device = device
        self.queue = queue
    }

    func run(
        configuration: BlurConfiguration,
        matchedSigma: Float,
        width: Int,
        height: Int,
        warmUpIterations: Int = 30,
        measuredIterations: Int = 300,
        progress: @MainActor (Double) -> Void = { _ in }
    ) async throws -> Output {
        let source = try makeSource(width: width, height: height)
        let dualDestination = try makeDestination(width: width, height: height, usage: [.renderTarget, .shaderRead])
        let gaussianDestination = try makeDestination(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        let dualEncoder = try BenchmarkBlurEncoder(
            device: device,
            width: width,
            height: height,
            pixelFormat: .bgra8Unorm,
            configuration: configuration
        )
        let gaussian = MPSImageGaussianBlur(device: device, sigma: matchedSigma)
        gaussian.edgeMode = .clamp

        for iteration in 0..<warmUpIterations {
            if iteration.isMultiple(of: 2) {
                _ = try await execute { try dualEncoder.encode(source: source, destination: dualDestination, into: $0) }
                _ = try await execute { gaussian.encode(commandBuffer: $0, sourceTexture: source, destinationTexture: gaussianDestination) }
            } else {
                _ = try await execute { gaussian.encode(commandBuffer: $0, sourceTexture: source, destinationTexture: gaussianDestination) }
                _ = try await execute { try dualEncoder.encode(source: source, destination: dualDestination, into: $0) }
            }
        }

        var dualSamples = Samples()
        var gaussianSamples = Samples()
        dualSamples.reserveCapacity(measuredIterations)
        gaussianSamples.reserveCapacity(measuredIterations)

        for iteration in 0..<measuredIterations {
            try Task.checkCancellation()
            if iteration.isMultiple(of: 2) {
                dualSamples.append(try await execute { try dualEncoder.encode(source: source, destination: dualDestination, into: $0) })
                gaussianSamples.append(try await execute { gaussian.encode(commandBuffer: $0, sourceTexture: source, destinationTexture: gaussianDestination) })
            } else {
                gaussianSamples.append(try await execute { gaussian.encode(commandBuffer: $0, sourceTexture: source, destinationTexture: gaussianDestination) })
                dualSamples.append(try await execute { try dualEncoder.encode(source: source, destination: dualDestination, into: $0) })
            }
            progress(Double(iteration + 1) / Double(measuredIterations))
        }

        return Output(
            dualKawase: dualSamples,
            mpsGaussian: gaussianSamples,
            warmUpIterations: warmUpIterations,
            measuredIterations: measuredIterations
        )
    }

    private func execute(encode: (MTLCommandBuffer) throws -> Void) async throws -> (Double, Double, Double) {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw RunnerError.commandFailed }
        let endToEndStart = CACurrentMediaTime()
        let cpuStart = CACurrentMediaTime()
        try encode(commandBuffer)
        let cpuMilliseconds = (CACurrentMediaTime() - cpuStart) * 1_000
        let completed = await commit(commandBuffer)
        guard completed.completed else { throw RunnerError.commandFailed }
        let endToEndMilliseconds = (CACurrentMediaTime() - endToEndStart) * 1_000
        return (cpuMilliseconds, completed.gpuMilliseconds, endToEndMilliseconds)
    }

    private func commit(_ commandBuffer: MTLCommandBuffer) async -> CompletedTiming {
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                continuation.resume(returning: CompletedTiming(
                    gpuMilliseconds: max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1_000,
                    completed: buffer.status == .completed
                ))
            }
            commandBuffer.commit()
        }
    }

    private func makeSource(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RunnerError.allocationFailed }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(truncatingIfNeeded: x &+ y)
                bytes[index + 1] = UInt8(truncatingIfNeeded: x &* 3)
                bytes[index + 2] = UInt8(truncatingIfNeeded: y &* 5)
            }
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: width * 4
        )
        return texture
    }

    private func makeDestination(width: Int, height: Int, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RunnerError.allocationFailed }
        return texture
    }
}

private extension BlurBenchmarkRunner.Samples {
    mutating func reserveCapacity(_ capacity: Int) {
        cpuEncodeMilliseconds.reserveCapacity(capacity)
        gpuMilliseconds.reserveCapacity(capacity)
        endToEndMilliseconds.reserveCapacity(capacity)
    }

    mutating func append(_ sample: (Double, Double, Double)) {
        cpuEncodeMilliseconds.append(sample.0)
        gpuMilliseconds.append(sample.1)
        endToEndMilliseconds.append(sample.2)
    }
}
