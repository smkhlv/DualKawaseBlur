import Metal

/// Benchmark-only compute implementation used to separate render-pass overhead
/// from the cost of the Dual Kawase sampling pattern.
@_spi(Benchmark)
public final class ComputeDualKawaseBlurEncoder {
    public struct ThreadgroupSize: Sendable, Hashable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public enum Mode: Sendable, Equatable {
        /// Same reduction count and 5/8-tap filters as the shipped renderer.
        case faithful
        /// Same reduction count, with a lower-cost moment-matched four-tap final reconstruction.
        case momentMatchedFinal
        /// Same reduction count and second moment, using an equilateral three-tap final reconstruction.
        case triangularMomentMatchedFinal
        /// Four-tap moment matching at intermediate restores, followed by the three-tap final restore.
        case allLevelMomentMatched
        /// Four-tap downsample and intermediate restore, followed by the three-tap final restore.
        case fourTapDownsampleAllLevelMomentMatched
    }

    public let reductionLevelCount: Int
    public let downsampleTapCount: Int
    public let intermediateUpsampleTapCount: Int
    public let finalUpsampleTapCount: Int
    public let threadgroupSize: ThreadgroupSize

    private let device: MTLDevice
    private let inputWidth: Int
    private let inputHeight: Int
    private let pixelFormat: MTLPixelFormat
    private let offset: Float
    private let mode: Mode
    private let textures: [MTLTexture]
    private let downsample5TapPipeline: MTLComputePipelineState
    private let downsample4TapPipeline: MTLComputePipelineState
    private let upsample8TapPipeline: MTLComputePipelineState
    private let upsample4TapPipeline: MTLComputePipelineState
    private let upsample3TapPipeline: MTLComputePipelineState

    public init(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        configuration: BlurConfiguration,
        mode: Mode,
        threadgroupSize requestedThreadgroupSize: ThreadgroupSize? = nil
    ) throws {
        try configuration.validate(forWidth: width, height: height)
        guard pixelFormat == .bgra8Unorm else {
            throw DualKawaseBlurError.unsupportedTexture
        }

        let levelCount = configuration.iterations
        let candidateConfiguration = BlurConfiguration(
            iterations: levelCount,
            offset: configuration.offset
        )
        let layout: TexturePyramidLayout
        do {
            layout = try TexturePyramidLayout(
                width: width,
                height: height,
                configuration: candidateConfiguration
            )
        } catch {
            throw DualKawaseBlurError.invalidConfiguration
        }

        let context = try MetalContext(device: device)
        guard
            let downsample5TapFunction = context.library.makeFunction(name: "downsampleCompute"),
            let downsample4TapFunction = context.library.makeFunction(name: "downsampleCompute4Tap"),
            let upsample8TapFunction = context.library.makeFunction(name: "upsampleCompute8Tap"),
            let upsample4TapFunction = context.library.makeFunction(name: "upsampleCompute4Tap"),
            let upsample3TapFunction = context.library.makeFunction(name: "upsampleCompute3Tap")
        else {
            throw DualKawaseBlurError.pipelineCreationFailed
        }
        do {
            downsample5TapPipeline = try device.makeComputePipelineState(function: downsample5TapFunction)
            downsample4TapPipeline = try device.makeComputePipelineState(function: downsample4TapFunction)
            upsample8TapPipeline = try device.makeComputePipelineState(function: upsample8TapFunction)
            upsample4TapPipeline = try device.makeComputePipelineState(function: upsample4TapFunction)
            upsample3TapPipeline = try device.makeComputePipelineState(function: upsample3TapFunction)
        } catch {
            throw DualKawaseBlurError.pipelineCreationFailed
        }

        textures = try layout.levels.map { level in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: level.width,
                height: level.height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DualKawaseBlurError.textureAllocationFailed
            }
            return texture
        }

        self.device = device
        inputWidth = width
        inputHeight = height
        self.pixelFormat = pixelFormat
        offset = configuration.offset
        self.mode = mode
        reductionLevelCount = levelCount
        downsampleTapCount = switch mode {
        case .faithful, .momentMatchedFinal, .triangularMomentMatchedFinal, .allLevelMomentMatched: 5
        case .fourTapDownsampleAllLevelMomentMatched: 4
        }
        intermediateUpsampleTapCount = switch mode {
        case .faithful, .momentMatchedFinal, .triangularMomentMatchedFinal: 8
        case .allLevelMomentMatched, .fourTapDownsampleAllLevelMomentMatched: 4
        }
        finalUpsampleTapCount = switch mode {
        case .faithful: 8
        case .momentMatchedFinal: 4
        case .triangularMomentMatchedFinal, .allLevelMomentMatched,
             .fourTapDownsampleAllLevelMomentMatched: 3
        }

        let pipelines = [
            downsample5TapPipeline,
            downsample4TapPipeline,
            upsample8TapPipeline,
            upsample4TapPipeline,
            upsample3TapPipeline
        ]
        let defaultSize = Self.defaultThreadgroupSize(for: pipelines)
        let selectedSize = requestedThreadgroupSize ?? defaultSize
        guard Self.isSupported(selectedSize, by: pipelines) else {
            throw DualKawaseBlurError.invalidConfiguration
        }
        threadgroupSize = selectedSize
    }

    /// A bounded set of portable two-dimensional shapes suitable for preflight timing.
    public var threadgroupCandidates: [ThreadgroupSize] {
        let pipelines = [
            downsample5TapPipeline,
            downsample4TapPipeline,
            upsample8TapPipeline,
            upsample4TapPipeline,
            upsample3TapPipeline
        ]
        let candidates = [
            threadgroupSize,
            ThreadgroupSize(width: 8, height: 8),
            ThreadgroupSize(width: 16, height: 8),
            ThreadgroupSize(width: 32, height: 4),
            ThreadgroupSize(width: 16, height: 16),
            ThreadgroupSize(width: 32, height: 8),
            ThreadgroupSize(width: 8, height: 32)
        ]
        var seen = Set<ThreadgroupSize>()
        return candidates.filter { seen.insert($0).inserted && Self.isSupported($0, by: pipelines) }
    }

    public func encode(
        source: MTLTexture,
        destination: MTLTexture,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        try validate(source: source, destination: destination, commandBuffer: commandBuffer)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DualKawaseBlurError.commandBufferCreationFailed
        }
        defer { encoder.endEncoding() }

        var current = source
        let downsamplePipeline = mode == .fourTapDownsampleAllLevelMomentMatched
            ? downsample4TapPipeline
            : downsample5TapPipeline
        for texture in textures {
            dispatch(
                pipeline: downsamplePipeline,
                source: current,
                destination: texture,
                encoder: encoder
            )
            encoder.memoryBarrier(resources: [texture])
            current = texture
        }

        let intermediateUpsamplePipeline: MTLComputePipelineState
        switch mode {
        case .allLevelMomentMatched, .fourTapDownsampleAllLevelMomentMatched:
            intermediateUpsamplePipeline = upsample4TapPipeline
        case .faithful, .momentMatchedFinal, .triangularMomentMatchedFinal:
            intermediateUpsamplePipeline = upsample8TapPipeline
        }
        for index in textures.indices.dropFirst().reversed() {
            let texture = textures[index - 1]
            dispatch(
                pipeline: intermediateUpsamplePipeline,
                source: textures[index],
                destination: texture,
                encoder: encoder
            )
            encoder.memoryBarrier(resources: [texture])
        }

        guard let firstTexture = textures.first else {
            throw DualKawaseBlurError.textureAllocationFailed
        }

        let finalPipeline: MTLComputePipelineState
        switch mode {
        case .faithful: finalPipeline = upsample8TapPipeline
        case .momentMatchedFinal: finalPipeline = upsample4TapPipeline
        case .triangularMomentMatchedFinal, .allLevelMomentMatched,
             .fourTapDownsampleAllLevelMomentMatched:
            finalPipeline = upsample3TapPipeline
        }
        dispatch(
            pipeline: finalPipeline,
            source: firstTexture,
            destination: destination,
            encoder: encoder
        )
    }

    private func dispatch(
        pipeline: MTLComputePipelineState,
        source: MTLTexture,
        destination: MTLTexture,
        encoder: MTLComputeCommandEncoder
    ) {
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        var sampleStep = SIMD2<Float>(
            offset * 0.5 / Float(destination.width),
            offset * 0.5 / Float(destination.height)
        )
        encoder.setBytes(&sampleStep, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)

        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadgroupSize.width,
                height: threadgroupSize.height,
                depth: 1
            )
        )
    }

    private static func defaultThreadgroupSize(
        for pipelines: [MTLComputePipelineState]
    ) -> ThreadgroupSize {
        guard let first = pipelines.first else { return .init(width: 1, height: 1) }
        let width = first.threadExecutionWidth
        let maximumHeight = pipelines.map { $0.maxTotalThreadsPerThreadgroup / width }.min() ?? 1
        let preferred = ThreadgroupSize(width: width, height: max(1, min(8, maximumHeight)))
        return isSupported(preferred, by: pipelines)
            ? preferred
            : ThreadgroupSize(width: width, height: 1)
    }

    private static func isSupported(
        _ size: ThreadgroupSize,
        by pipelines: [MTLComputePipelineState]
    ) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let threadCount = size.width * size.height
        return pipelines.allSatisfy { pipeline in
            threadCount <= pipeline.maxTotalThreadsPerThreadgroup
                && threadCount.isMultiple(of: pipeline.threadExecutionWidth)
        }
    }

    private func validate(
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard source.width == inputWidth,
              source.height == inputHeight,
              destination.width == inputWidth,
              destination.height == inputHeight,
              source.pixelFormat == pixelFormat,
              destination.pixelFormat == pixelFormat,
              source.device === device,
              destination.device === device,
              commandBuffer.device === device,
              source.usage.isEmpty || source.usage.contains(.shaderRead),
              destination.usage.isEmpty || destination.usage.contains(.shaderWrite) else {
            throw DualKawaseBlurError.unsupportedTexture
        }
    }
}
