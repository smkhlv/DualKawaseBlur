import Metal

/// One step of the split schedule. Level indices: -1 is the source, 0 is the half-size level.
enum SplitStage: Equatable {
    case renderDownsample(from: Int, to: Int)
    case compute([SplitComputePass])
    case renderRestore(from: Int, to: Int)
    case renderFinal(from: Int)
}

enum SplitComputePass: Equatable {
    case downsample(from: Int, to: Int)
    case upsample(from: Int, to: Int)
}

/// The compiled pipelines of the split schedule. They depend only on the library and the fixed
/// `.bgra8Unorm` format, so a session builds one set and every encoder reuses it.
struct SplitRolePipelines {
    let downsample: MTLRenderPipelineState
    let restore: MTLRenderPipelineState
    let final: MTLRenderPipelineState
    let computeDownsample: MTLComputePipelineState
    let computeUpsample: MTLComputePipelineState

    init(context: MetalContext) throws {
        let device = context.device
        func renderPipeline(_ name: String) throws -> MTLRenderPipelineState {
            try RedistributedRender.pipeline(name, context: context, device: device, pixelFormat: .bgra8Unorm)
        }
        downsample = try renderPipeline("downsampleFragment4Tap443")
        restore = try renderPipeline("upsampleFragment4Tap443")
        final = try renderPipeline("upsampleFragment1TapRedistributed443")
        computeDownsample = try SplitRoleBlurEncoder.computePipeline("downsampleCompute4Tap", context: context,
                                                                     device: device)
        computeUpsample = try SplitRoleBlurEncoder.computePipeline("upsampleCompute4Tap", context: context,
                                                                   device: device)
    }
}

/// Split of the all-render 4/4/1 approximation: render passes for the three large passes, one
/// compute encoder for the small ones. Same math as `RedistributedAllRenderBlurEncoder`.
/// Resources are allocated before encoding. It is the blur of `SharedMetalBlurSession`, which stops at
/// the half-size level 0 (`encodeThroughLevelZero`); `encode` adds the full-size final pass and is the
/// benchmark entry point, like the public init.
/// Not concurrently reusable: its intermediate textures belong to one in-flight sequence.
@_spi(Benchmark)
public final class SplitRoleBlurEncoder {
    static let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)

    private let device: MTLDevice
    private let width: Int
    private let height: Int
    private let offset: Float
    private let stages: [SplitStage]
    // Internal for invariant tests; never writable through the benchmark SPI.
    let intermediateTextures: [MTLTexture]
    // Internal for the sharing invariant test.
    let pipelines: SplitRolePipelines

    public convenience init(device: MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat,
                            configuration: BlurConfiguration) throws {
        let layout = try Self.validateSupport(width: width, height: height, pixelFormat: pixelFormat,
                                              configuration: configuration)
        try self.init(pipelines: SplitRolePipelines(context: MetalContext(device: device)), layout: layout,
                      width: width, height: height, pixelFormat: pixelFormat, offset: configuration.offset,
                      device: device)
    }

    /// Reuses `pipelines`, which a session builds once; `layout` comes from `validateSupport`.
    init(pipelines: SplitRolePipelines, layout: TexturePyramidLayout, width: Int, height: Int,
         pixelFormat: MTLPixelFormat, offset: Float, device: MTLDevice) throws {
        self.pipelines = pipelines
        intermediateTextures = try Self.makeIntermediates(layout: layout, device: device, pixelFormat: pixelFormat)
        stages = Self.plan(levelCount: layout.levels.count)
        self.device = device
        self.width = width
        self.height = height
        self.offset = offset
    }

    /// The guards of the split schedule: at least two pyramid levels and a `.bgra8Unorm` source.
    /// Run before any pipeline or texture is built.
    static func validateSupport(width: Int, height: Int, pixelFormat: MTLPixelFormat,
                                configuration: BlurConfiguration) throws -> TexturePyramidLayout {
        let layout = try TexturePyramidLayout(width: width, height: height, configuration: configuration)
        guard pixelFormat == .bgra8Unorm else { throw DualKawaseBlurError.unsupportedTexture }
        guard layout.levels.count >= 2 else { throw DualKawaseBlurError.invalidConfiguration }
        return layout
    }

    /// Shared with the Metal 4 twin; rejects pipelines that can't run the 8×8 threadgroup.
    static func computePipeline(_ name: String, context: MetalContext,
                                device: MTLDevice) throws -> MTLComputePipelineState {
        guard let function = context.library.makeFunction(name: name) else {
            throw DualKawaseBlurError.pipelineCreationFailed
        }
        let pipeline: MTLComputePipelineState
        do { pipeline = try device.makeComputePipelineState(function: function) }
        catch { throw DualKawaseBlurError.pipelineCreationFailed }
        let threads = threadgroupSize.width * threadgroupSize.height
        guard threads <= pipeline.maxTotalThreadsPerThreadgroup,
              threads.isMultiple(of: pipeline.threadExecutionWidth) else {
            throw DualKawaseBlurError.invalidConfiguration
        }
        return pipeline
    }

    /// Private pyramid levels, shared with the Metal 4 twin.
    static func makeIntermediates(layout: TexturePyramidLayout, device: MTLDevice,
                                  pixelFormat: MTLPixelFormat) throws -> [MTLTexture] {
        try layout.levels.enumerated().map { index, level in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                width: level.width, height: level.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.hazardTrackingMode = .tracked
            // Level 0 is only render-written, so it never gets shaderWrite and keeps lossless compression.
            descriptor.usage = index == 0 ? [.shaderRead, .renderTarget] : [.shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DualKawaseBlurError.textureAllocationFailed
            }
            return texture
        }
    }

    /// Render for the three large passes; every small pass shares one compute encoder.
    static func plan(levelCount: Int) -> [SplitStage] {
        precondition(levelCount >= 2, "split schedule needs at least two levels")
        var passes = (0..<(levelCount - 1)).map { SplitComputePass.downsample(from: $0, to: $0 + 1) }
        passes += (1..<(levelCount - 1)).reversed().map { SplitComputePass.upsample(from: $0 + 1, to: $0) }
        return [.renderDownsample(from: -1, to: 0), .compute(passes),
                .renderRestore(from: 1, to: 0), .renderFinal(from: 0)]
    }

    public func encode(source: MTLTexture, destination: MTLTexture, into buffer: MTLCommandBuffer) throws {
        try RedistributedRender.validate(source: source, destination: destination, buffer: buffer,
            intermediates: intermediateTextures, device: device, width: width, height: height)
        try encodeStages(source: source, destination: destination, into: buffer)
    }

    /// Runs every stage but the full-size final pass and returns the half-size level 0, the blurred image
    /// at half resolution. The texture is this encoder's own intermediate: it is rewritten by the next
    /// encode, so a caller that reads it later owns the sequencing (the shared session leases it per slot).
    public func encodeThroughLevelZero(source: MTLTexture, into buffer: MTLCommandBuffer) throws -> MTLTexture {
        try RedistributedRender.validate(source: source, buffer: buffer, intermediates: intermediateTextures,
            device: device, width: width, height: height)
        try encodeStages(source: source, destination: nil, into: buffer)
        return intermediateTextures[0]
    }

    /// A nil `destination` skips the final pass.
    private func encodeStages(source: MTLTexture, destination: MTLTexture?,
                              into buffer: MTLCommandBuffer) throws {
        func texture(_ level: Int) -> MTLTexture { level < 0 ? source : intermediateTextures[level] }
        for stage in stages {
            switch stage {
            case let .renderDownsample(from, to):
                try render(texture(from), to: texture(to), pipeline: pipelines.downsample, into: buffer)
            case let .compute(passes):
                try encodeCompute(passes, texture: texture, into: buffer)
            case let .renderRestore(from, to):
                try render(texture(from), to: texture(to), pipeline: pipelines.restore, compensate: true,
                           into: buffer)
            case let .renderFinal(from):
                guard let destination else { continue }
                try render(texture(from), to: destination, pipeline: pipelines.final, finalPass: true,
                           into: buffer)
            }
        }
    }

    private func encodeCompute(_ passes: [SplitComputePass], texture: (Int) -> MTLTexture,
                               into buffer: MTLCommandBuffer) throws {
        guard let encoder = buffer.makeComputeCommandEncoder() else {
            throw DualKawaseBlurError.commandBufferCreationFailed
        }
        defer { encoder.endEncoding() }
        for (index, pass) in passes.enumerated() {
            let (pipeline, source, destination): (MTLComputePipelineState, MTLTexture, MTLTexture)
            switch pass {
            case let .downsample(from, to):
                (pipeline, source, destination) = (pipelines.computeDownsample, texture(from), texture(to))
            case let .upsample(from, to):
                (pipeline, source, destination) = (pipelines.computeUpsample, texture(from), texture(to))
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            var sampleStep = RedistributedRender.step(offset: offset, width: destination.width,
                                                      height: destination.height)
            encoder.setBytes(&sampleStep, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                    threadsPerThreadgroup: Self.threadgroupSize)
            // The next dispatch reads this destination (serial dispatch still needs the barrier).
            if index < passes.count - 1 { encoder.memoryBarrier(resources: [destination]) }
        }
    }

    private func render(_ source: MTLTexture, to destination: MTLTexture,
                        pipeline: MTLRenderPipelineState, finalPass: Bool = false,
                        compensate: Bool = false,
                        into buffer: MTLCommandBuffer) throws {
        try RedistributedRender.render(source, to: destination, pipeline: pipeline, offset: offset,
            fullWidth: width, fullHeight: height, finalPass: finalPass, compensate: compensate, into: buffer)
    }
}
