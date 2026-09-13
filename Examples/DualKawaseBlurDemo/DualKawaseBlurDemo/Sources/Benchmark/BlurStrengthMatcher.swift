import Metal
import MetalPerformanceShaders
@_spi(Benchmark) import DualKawaseBlur

@MainActor
final class BlurStrengthMatcher {
    struct Result: Sendable {
        let sigma: Float
        let targetSecondMoment: Double
        let gaussianSecondMoment: Double
        let impulseNormalizedRMSE: Double
        let fixtureNormalizedRMSE: Double

        var residualError: Double {
            (impulseNormalizedRMSE + fixtureNormalizedRMSE) / 2
        }
    }

    enum MatchError: Error { case metalUnavailable, allocationFailed, commandFailed }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let engine: DualKawaseBlurEngine

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw MatchError.metalUnavailable
        }
        self.device = device
        self.queue = queue
        engine = try DualKawaseBlurEngine(device: device)
    }

    func match(
        configuration: BlurConfiguration,
        textureSize: Int = 257,
        sigmaRange: ClosedRange<Float> = 0.5...96,
        searchIterations: Int = 12
    ) async throws -> Result {
        let impulse = try makeFixture(size: textureSize, kind: .impulse)
        let dualImpulse = try await renderDual(source: impulse, configuration: configuration)
        let targetMoment = radialSecondMoment(dualImpulse, size: textureSize)

        var lower = sigmaRange.lowerBound
        var upper = sigmaRange.upperBound
        var bestSigma = lower
        var bestSamples: [Double] = []
        var bestMoment = 0.0
        var bestDistance = Double.infinity

        for _ in 0..<max(1, searchIterations) {
            let sigma = (lower + upper) / 2
            let samples = try await renderGaussian(source: impulse, sigma: sigma)
            let moment = radialSecondMoment(samples, size: textureSize)
            let distance = abs(moment - targetMoment)
            if distance < bestDistance {
                bestDistance = distance
                bestSigma = sigma
                bestSamples = samples
                bestMoment = moment
            }
            if moment < targetMoment { lower = sigma } else { upper = sigma }
        }

        let fixture = try makeFixture(size: textureSize, kind: .photographic)
        let dualFixture = try await renderDual(source: fixture, configuration: configuration)
        let gaussianFixture = try await renderGaussian(source: fixture, sigma: bestSigma)

        return Result(
            sigma: bestSigma,
            targetSecondMoment: targetMoment,
            gaussianSecondMoment: bestMoment,
            impulseNormalizedRMSE: BenchmarkMath.normalizedRMSE(dualImpulse, bestSamples),
            fixtureNormalizedRMSE: BenchmarkMath.normalizedRMSE(dualFixture, gaussianFixture)
        )
    }

    private enum FixtureKind { case impulse, photographic }

    private func makeFixture(size: Int, kind: FixtureKind) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MatchError.allocationFailed
        }
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let value: UInt8
                switch kind {
                case .impulse:
                    value = x == size / 2 && y == size / 2 ? 255 : 0
                case .photographic:
                    let gradient = Double(x) / Double(max(1, size - 1))
                    let dx = Double(x - size / 3), dy = Double(y - size / 2)
                    let disk = dx * dx + dy * dy < Double(size * size) * 0.035
                    value = UInt8(clamping: Int((disk ? 0.9 : 0.15 + gradient * 0.65) * 255))
                }
                let offset = (y * size + x) * 4
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: size * 4
        )
        return texture
    }

    private func renderDual(source: MTLTexture, configuration: BlurConfiguration) async throws -> [Double] {
        let destination = try makeTexture(size: source.width, usage: [.renderTarget, .shaderRead])
        return try await render(source: source, destination: destination) { commandBuffer in
            try engine.encode(source: source, destination: destination, configuration: configuration, into: commandBuffer)
        }
    }

    private func renderGaussian(source: MTLTexture, sigma: Float) async throws -> [Double] {
        let destination = try makeTexture(size: source.width, usage: [.shaderRead, .shaderWrite])
        return try await render(source: source, destination: destination) { commandBuffer in
            let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
            blur.edgeMode = .clamp
            blur.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destination)
        }
    }

    private func render(
        source: MTLTexture,
        destination: MTLTexture,
        encode: (MTLCommandBuffer) throws -> Void
    ) async throws -> [Double] {
        let readback = try makeTexture(size: source.width, usage: [])
        guard let commandBuffer = queue.makeCommandBuffer() else { throw MatchError.commandFailed }
        try encode(commandBuffer)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw MatchError.commandFailed }
        blit.copy(
            from: destination, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
            sourceSize: .init(width: destination.width, height: destination.height, depth: 1),
            to: readback, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init()
        )
        blit.endEncoding()
        try await commit(commandBuffer)
        return luminance(from: readback)
    }

    private func makeTexture(size: Int, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = usage.isEmpty ? .shared : .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MatchError.allocationFailed
        }
        return texture
    }

    private func commit(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                buffer.status == .completed
                    ? continuation.resume()
                    : continuation.resume(throwing: MatchError.commandFailed)
            }
            commandBuffer.commit()
        }
    }

    private func luminance(from texture: MTLTexture) -> [Double] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &bytes, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
        )
        return stride(from: 0, to: bytes.count, by: 4).map { Double(bytes[$0]) / 255 }
    }

    private func radialSecondMoment(_ values: [Double], size: Int) -> Double {
        let center = Double(size - 1) / 2
        var weightedRadius = 0.0
        var total = 0.0
        for (index, value) in values.enumerated() {
            let x = Double(index % size) - center
            let y = Double(index / size) - center
            weightedRadius += value * (x * x + y * y)
            total += value
        }
        return total > 0 ? weightedRadius / total : 0
    }
}
