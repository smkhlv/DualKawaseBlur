import Metal

/// Opt-in all-render 4/4/1 approximation, same covariance redistribution as hybrid R.
/// Resources and all pipelines are allocated before encoding; no production selection.
/// Not concurrently reusable: its intermediate textures belong to one in-flight sequence.
@_spi(Benchmark)
public final class RedistributedAllRenderBlurEncoder {
    private let device: MTLDevice
    private let width: Int
    private let height: Int
    private let offset: Float
    // Internal for invariant tests; never writable through the benchmark SPI.
    let intermediateTextures: [MTLTexture]
    private let downsample: MTLRenderPipelineState
    private let upsample: MTLRenderPipelineState
    private let final: MTLRenderPipelineState

    public init(device: MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat,
                configuration: BlurConfiguration) throws {
        let layout = try TexturePyramidLayout(width: width, height: height, configuration: configuration)
        guard pixelFormat == .bgra8Unorm else { throw DualKawaseBlurError.unsupportedTexture }
        guard layout.levels.count >= 2 else { throw DualKawaseBlurError.invalidConfiguration }
        let context = try MetalContext(device: device)
        func pipeline(_ name: String) throws -> MTLRenderPipelineState {
            try RedistributedRender.pipeline(name, context: context, device: device, pixelFormat: pixelFormat)
        }
        downsample = try pipeline("downsampleFragment4Tap443")
        upsample = try pipeline("upsampleFragment4Tap443")
        final = try pipeline("upsampleFragment1TapRedistributed443")
        intermediateTextures = try layout.levels.map { level in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                width: level.width, height: level.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.hazardTrackingMode = .tracked
            descriptor.usage = [.shaderRead, .renderTarget]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DualKawaseBlurError.textureAllocationFailed
            }
            return texture
        }
        self.device = device
        self.width = width
        self.height = height
        offset = configuration.offset
    }

    public func encode(source: MTLTexture, destination: MTLTexture, into buffer: MTLCommandBuffer) throws {
        try RedistributedRender.validate(source: source, destination: destination, buffer: buffer,
            intermediates: intermediateTextures, device: device, width: width, height: height)
        var current = source
        for texture in intermediateTextures {
            try render(current, to: texture, pipeline: downsample, into: buffer)
            current = texture
        }
        for texture in intermediateTextures.dropLast().reversed() {
            try render(current, to: texture, pipeline: upsample,
                       compensate: texture === intermediateTextures.first, into: buffer)
            current = texture
        }
        try render(current, to: destination, pipeline: final, finalPass: true, into: buffer)
    }

    private func render(_ source: MTLTexture, to destination: MTLTexture,
                        pipeline: MTLRenderPipelineState, finalPass: Bool = false,
                        compensate: Bool = false,
                        into buffer: MTLCommandBuffer) throws {
        try RedistributedRender.render(source, to: destination, pipeline: pipeline, offset: offset,
            fullWidth: width, fullHeight: height, finalPass: finalPass, compensate: compensate, into: buffer)
    }

    /// Axis-specific compensation for floor-divided (including odd-sized) pyramids.
    static func redistributedPenultimateStep(offset: Float, width: Int, height: Int,
                                            fullWidth: Int, fullHeight: Int) -> SIMD2<Float> {
        let ratio = SIMD2<Float>(Float(width) / Float(fullWidth), Float(height) / Float(fullHeight))
        return SIMD2<Float>(offset * 0.5 / Float(width) * (1 + ratio.x * ratio.x).squareRoot(),
                            offset * 0.5 / Float(height) * (1 + ratio.y * ratio.y).squareRoot())
    }
}
