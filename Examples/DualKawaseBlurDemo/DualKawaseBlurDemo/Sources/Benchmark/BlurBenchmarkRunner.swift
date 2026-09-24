import Metal
import MetalPerformanceShaders
import QuartzCore
@_spi(Benchmark) import DualKawaseBlur

@MainActor
final class BlurBenchmarkRunner {
    enum Variant: CaseIterable, Sendable, Hashable {
        case dualKawase
        case triangularMomentMatchedDualKawase
        case allLevelDefaultThreadgroup
        case allLevelTunedThreadgroup
        case fourTapDownsampleDualKawase
        case mpsGaussian
    }

    struct Samples: Sendable {
        var cpuEncodeMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var endToEndMilliseconds: [Double] = []
    }

    struct ThreadgroupTuning: Sendable {
        struct Candidate: Sendable {
            let width: Int
            let height: Int
            let gpuP50: Double
        }

        let warmUpIterations: Int
        let measuredIterations: Int
        let defaultSize: ComputeDualKawaseBlurEncoder.ThreadgroupSize
        let selectedSize: ComputeDualKawaseBlurEncoder.ThreadgroupSize
        let candidates: [Candidate]
    }

    struct Quality: Sendable {
        let triangularMPS: Double
        let triangularRenderDual: Double
        let allLevelDefaultMPS: Double
        let allLevelDefaultRenderDual: Double
        let allLevelDefaultThreeTap: Double
        let allLevelTunedMPS: Double
        let allLevelTunedRenderDual: Double
        let allLevelTunedDefault: Double
        let fourTapDownsampleMPS: Double
        let fourTapDownsampleRenderDual: Double
        let fourTapDownsampleAllLevel: Double
    }

    struct ComputeProfile: Sendable {
        let reductionLevelCount: Int
        let downsampleTapCount: Int
        let intermediateUpsampleTapCount: Int
        let finalUpsampleTapCount: Int
        let threadgroupSize: ComputeDualKawaseBlurEncoder.ThreadgroupSize
    }

    struct Output: Sendable {
        let dualKawase: Samples
        let triangularMomentMatchedDualKawase: Samples
        let allLevelDefaultThreadgroup: Samples
        let allLevelTunedThreadgroup: Samples
        let fourTapDownsampleDualKawase: Samples
        let mpsGaussian: Samples
        let quality: Quality
        let triangularEncoder: ComputeProfile
        let allLevelDefaultEncoder: ComputeProfile
        let allLevelTunedEncoder: ComputeProfile
        let fourTapDownsampleEncoder: ComputeProfile
        let threadgroupTuning: ThreadgroupTuning
        let warmUpIterations: Int
        let measuredIterations: Int
    }

    enum RunnerError: Error { case metalUnavailable, allocationFailed, commandFailed }

    private struct CompletedTiming: Sendable {
        let gpuMilliseconds: Double
        let completed: Bool
    }

    private struct Destinations {
        let dual: MTLTexture
        let triangular: MTLTexture
        let allLevelDefault: MTLTexture
        let allLevelTuned: MTLTexture
        let fourTapDownsample: MTLTexture
        let gaussian: MTLTexture
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
        sigma: Float,
        width: Int,
        height: Int,
        sourcePixels: Data,
        warmUpIterations: Int = 30,
        measuredIterations: Int = 300,
        progress: @MainActor (Double) -> Void = { _ in }
    ) async throws -> Output {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              sourcePixels.count == width * height * 4,
              sigma.isFinite, sigma > 0,
              warmUpIterations >= 0, measuredIterations > 0 else {
            throw RunnerError.allocationFailed
        }
        try Task.checkCancellation()

        let source = try makeSource(width: width, height: height, bytes: sourcePixels)
        let tuningDestination = try makeDestination(
            width: width,
            height: height,
            usage: [.shaderRead, .shaderWrite]
        )
        let tuning = try await tuneThreadgroup(
            configuration: configuration,
            width: width,
            height: height,
            source: source,
            destination: tuningDestination
        )
        try Task.checkCancellation()

        let destinations = try Destinations(
            dual: makeDestination(width: width, height: height, usage: [.renderTarget, .shaderRead]),
            triangular: makeDestination(width: width, height: height, usage: [.shaderRead, .shaderWrite]),
            allLevelDefault: makeDestination(width: width, height: height, usage: [.shaderRead, .shaderWrite]),
            allLevelTuned: makeDestination(width: width, height: height, usage: [.shaderRead, .shaderWrite]),
            fourTapDownsample: makeDestination(width: width, height: height, usage: [.shaderRead, .shaderWrite]),
            gaussian: makeDestination(width: width, height: height, usage: [.shaderRead, .shaderWrite])
        )
        let dualEncoder = try BenchmarkBlurEncoder(
            device: device,
            width: width,
            height: height,
            pixelFormat: .bgra8Unorm,
            configuration: configuration
        )
        let triangularEncoder = try makeComputeEncoder(
            width: width,
            height: height,
            configuration: configuration,
            mode: .triangularMomentMatchedFinal,
            threadgroupSize: tuning.defaultSize
        )
        let allLevelDefaultEncoder = try makeComputeEncoder(
            width: width,
            height: height,
            configuration: configuration,
            mode: .allLevelMomentMatched,
            threadgroupSize: tuning.defaultSize
        )
        let allLevelTunedEncoder = try makeComputeEncoder(
            width: width,
            height: height,
            configuration: configuration,
            mode: .allLevelMomentMatched,
            threadgroupSize: tuning.selectedSize
        )
        let fourTapDownsampleEncoder = try makeComputeEncoder(
            width: width,
            height: height,
            configuration: configuration,
            mode: .fourTapDownsampleAllLevelMomentMatched,
            threadgroupSize: tuning.selectedSize
        )
        let gaussian = MPSImageGaussianBlur(device: device, sigma: sigma)
        gaussian.edgeMode = .clamp

        for iteration in 0..<warmUpIterations {
            try Task.checkCancellation()
            for variant in orderedVariants(for: iteration) {
                _ = try await execute(
                    variant: variant,
                    source: source,
                    destinations: destinations,
                    dualEncoder: dualEncoder,
                    triangularEncoder: triangularEncoder,
                    allLevelDefaultEncoder: allLevelDefaultEncoder,
                    allLevelTunedEncoder: allLevelTunedEncoder,
                    fourTapDownsampleEncoder: fourTapDownsampleEncoder,
                    gaussian: gaussian
                )
            }
        }

        var samples = Dictionary(uniqueKeysWithValues: Variant.allCases.map { ($0, Samples()) })
        for variant in Variant.allCases { samples[variant]?.reserveCapacity(measuredIterations) }

        for iteration in 0..<measuredIterations {
            try Task.checkCancellation()
            for variant in orderedVariants(for: iteration) {
                let timing = try await execute(
                    variant: variant,
                    source: source,
                    destinations: destinations,
                    dualEncoder: dualEncoder,
                    triangularEncoder: triangularEncoder,
                    allLevelDefaultEncoder: allLevelDefaultEncoder,
                    allLevelTunedEncoder: allLevelTunedEncoder,
                    fourTapDownsampleEncoder: fourTapDownsampleEncoder,
                    gaussian: gaussian
                )
                samples[variant]?.append(timing)
            }
            progress(Double(iteration + 1) / Double(measuredIterations))
        }

        try Task.checkCancellation()
        return Output(
            dualKawase: samples[.dualKawase]!,
            triangularMomentMatchedDualKawase: samples[.triangularMomentMatchedDualKawase]!,
            allLevelDefaultThreadgroup: samples[.allLevelDefaultThreadgroup]!,
            allLevelTunedThreadgroup: samples[.allLevelTunedThreadgroup]!,
            fourTapDownsampleDualKawase: samples[.fourTapDownsampleDualKawase]!,
            mpsGaussian: samples[.mpsGaussian]!,
            quality: try await readQuality(destinations),
            triangularEncoder: profile(triangularEncoder),
            allLevelDefaultEncoder: profile(allLevelDefaultEncoder),
            allLevelTunedEncoder: profile(allLevelTunedEncoder),
            fourTapDownsampleEncoder: profile(fourTapDownsampleEncoder),
            threadgroupTuning: tuning,
            warmUpIterations: warmUpIterations,
            measuredIterations: measuredIterations
        )
    }

    private func tuneThreadgroup(
        configuration: BlurConfiguration,
        width: Int,
        height: Int,
        source: MTLTexture,
        destination: MTLTexture,
        warmUpIterations: Int = 10,
        measuredIterations: Int = 50
    ) async throws -> ThreadgroupTuning {
        let probe = try makeComputeEncoder(
            width: width,
            height: height,
            configuration: configuration,
            mode: .allLevelMomentMatched,
            threadgroupSize: nil
        )
        let sizes = probe.threadgroupCandidates
        let encoders = try sizes.map { size in
            try makeComputeEncoder(
                width: width,
                height: height,
                configuration: configuration,
                mode: .allLevelMomentMatched,
                threadgroupSize: size
            )
        }

        for iteration in 0..<warmUpIterations {
            try Task.checkCancellation()
            for index in orderedIndices(count: encoders.count, iteration: iteration) {
                _ = try await execute { commandBuffer in
                    try encoders[index].encode(source: source, destination: destination, into: commandBuffer)
                }
            }
        }

        var gpuSamples = Array(repeating: [Double](), count: encoders.count)
        for index in gpuSamples.indices { gpuSamples[index].reserveCapacity(measuredIterations) }
        for iteration in 0..<measuredIterations {
            try Task.checkCancellation()
            for index in orderedIndices(count: encoders.count, iteration: iteration) {
                let timing = try await execute { commandBuffer in
                    try encoders[index].encode(source: source, destination: destination, into: commandBuffer)
                }
                gpuSamples[index].append(timing.1)
            }
        }

        let candidates = sizes.indices.map { index in
            ThreadgroupTuning.Candidate(
                width: sizes[index].width,
                height: sizes[index].height,
                gpuP50: BenchmarkMath.percentile(gpuSamples[index], 0.5)
            )
        }
        guard let selectedIndex = candidates.indices.min(by: {
            candidates[$0].gpuP50 < candidates[$1].gpuP50
        }) else { throw RunnerError.commandFailed }
        return .init(
            warmUpIterations: warmUpIterations,
            measuredIterations: measuredIterations,
            defaultSize: probe.threadgroupSize,
            selectedSize: sizes[selectedIndex],
            candidates: candidates
        )
    }

    private func makeComputeEncoder(
        width: Int,
        height: Int,
        configuration: BlurConfiguration,
        mode: ComputeDualKawaseBlurEncoder.Mode,
        threadgroupSize: ComputeDualKawaseBlurEncoder.ThreadgroupSize?
    ) throws -> ComputeDualKawaseBlurEncoder {
        try ComputeDualKawaseBlurEncoder(
            device: device,
            width: width,
            height: height,
            pixelFormat: .bgra8Unorm,
            configuration: configuration,
            mode: mode,
            threadgroupSize: threadgroupSize
        )
    }

    private func profile(_ encoder: ComputeDualKawaseBlurEncoder) -> ComputeProfile {
        .init(
            reductionLevelCount: encoder.reductionLevelCount,
            downsampleTapCount: encoder.downsampleTapCount,
            intermediateUpsampleTapCount: encoder.intermediateUpsampleTapCount,
            finalUpsampleTapCount: encoder.finalUpsampleTapCount,
            threadgroupSize: encoder.threadgroupSize
        )
    }

    private func orderedVariants(for iteration: Int) -> [Variant] {
        let variants = Variant.allCases
        let offset = iteration % variants.count
        return Array(variants[offset...] + variants[..<offset])
    }

    private func orderedIndices(count: Int, iteration: Int) -> [Int] {
        guard count > 0 else { return [] }
        let indices = Array(0..<count)
        let offset = iteration % count
        return Array(indices[offset...] + indices[..<offset])
    }

    private func execute(
        variant: Variant,
        source: MTLTexture,
        destinations: Destinations,
        dualEncoder: BenchmarkBlurEncoder,
        triangularEncoder: ComputeDualKawaseBlurEncoder,
        allLevelDefaultEncoder: ComputeDualKawaseBlurEncoder,
        allLevelTunedEncoder: ComputeDualKawaseBlurEncoder,
        fourTapDownsampleEncoder: ComputeDualKawaseBlurEncoder,
        gaussian: MPSImageGaussianBlur
    ) async throws -> (Double, Double, Double) {
        try await execute { commandBuffer in
            switch variant {
            case .dualKawase:
                try dualEncoder.encode(source: source, destination: destinations.dual, into: commandBuffer)
            case .triangularMomentMatchedDualKawase:
                try triangularEncoder.encode(source: source, destination: destinations.triangular, into: commandBuffer)
            case .allLevelDefaultThreadgroup:
                try allLevelDefaultEncoder.encode(source: source, destination: destinations.allLevelDefault, into: commandBuffer)
            case .allLevelTunedThreadgroup:
                try allLevelTunedEncoder.encode(source: source, destination: destinations.allLevelTuned, into: commandBuffer)
            case .fourTapDownsampleDualKawase:
                try fourTapDownsampleEncoder.encode(source: source, destination: destinations.fourTapDownsample, into: commandBuffer)
            case .mpsGaussian:
                gaussian.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: destinations.gaussian)
            }
        }
    }

    private func execute(
        encode: (MTLCommandBuffer) throws -> Void
    ) async throws -> (Double, Double, Double) {
        guard let commandBuffer = queue.makeCommandBuffer() else { throw RunnerError.commandFailed }
        let endToEndStart = CACurrentMediaTime()
        let cpuStart = CACurrentMediaTime()
        try encode(commandBuffer)
        let cpuMilliseconds = (CACurrentMediaTime() - cpuStart) * 1_000
        let completed = await commit(commandBuffer)
        guard completed.completed else { throw RunnerError.commandFailed }
        return (
            cpuMilliseconds,
            completed.gpuMilliseconds,
            (CACurrentMediaTime() - endToEndStart) * 1_000
        )
    }

    private func readQuality(_ destinations: Destinations) async throws -> Quality {
        let sources = [
            destinations.gaussian,
            destinations.dual,
            destinations.triangular,
            destinations.allLevelDefault,
            destinations.allLevelTuned,
            destinations.fourTapDownsample
        ]
        let readbacks = try sources.map(makeReadbackTexture)
        guard let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RunnerError.commandFailed
        }
        for (source, destination) in zip(sources, readbacks) {
            blit.copy(
                from: source,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: .init(),
                sourceSize: .init(width: source.width, height: source.height, depth: 1),
                to: destination,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: .init()
            )
        }
        blit.endEncoding()
        guard (await commit(commandBuffer)).completed else { throw RunnerError.commandFailed }

        let pixels = readbacks.map(self.pixels)
        let rmse: (Data, Data) -> Double = {
            BenchmarkMath.normalizedLumaRMSE(referenceBGRA: $0, candidateBGRA: $1)
        }
        let mps = pixels[0], render = pixels[1], triangular = pixels[2]
        let allDefault = pixels[3], allTuned = pixels[4], fourDown = pixels[5]
        return .init(
            triangularMPS: rmse(mps, triangular),
            triangularRenderDual: rmse(render, triangular),
            allLevelDefaultMPS: rmse(mps, allDefault),
            allLevelDefaultRenderDual: rmse(render, allDefault),
            allLevelDefaultThreeTap: rmse(triangular, allDefault),
            allLevelTunedMPS: rmse(mps, allTuned),
            allLevelTunedRenderDual: rmse(render, allTuned),
            allLevelTunedDefault: rmse(allDefault, allTuned),
            fourTapDownsampleMPS: rmse(mps, fourDown),
            fourTapDownsampleRenderDual: rmse(render, fourDown),
            fourTapDownsampleAllLevel: rmse(allTuned, fourDown)
        )
    }

    private func makeReadbackTexture(_ source: MTLTexture) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RunnerError.allocationFailed
        }
        return texture
    }

    private func pixels(_ texture: MTLTexture) -> Data {
        var pixels = Data(count: texture.width * texture.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return pixels
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

    private func makeSource(width: Int, height: Int, bytes: Data) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RunnerError.allocationFailed
        }
        bytes.withUnsafeBytes { storage in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: storage.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        return texture
    }

    private func makeDestination(
        width: Int,
        height: Int,
        usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RunnerError.allocationFailed
        }
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
