import Metal
import CoreGraphics

/// Executes the Dual Kawase Blur rendering algorithm
class BlurRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineCache: PipelineStateCache
    private let quad: FullScreenQuad

    enum RenderError: Error {
        case commandBufferCreationFailed
        case renderPassCreationFailed
    }

    init(device: MTLDevice, commandQueue: MTLCommandQueue, library: MTLLibrary) throws {
        self.device = device
        self.commandQueue = commandQueue
        self.pipelineCache = PipelineStateCache(device: device, library: library)
        self.quad = try FullScreenQuad(device: device)
    }

    /// Execute complete blur algorithm on texture pyramid
    /// - Parameters:
    ///   - source: Input texture to blur
    ///   - pyramid: Pre-allocated texture pyramid
    ///   - iterations: Number of blur iterations (1-5)
    ///   - offset: Blur radius multiplier (1.0-5.0)
    /// - Returns: Blurred texture (pyramid level 0)
    func executeBlur(
        source: MTLTexture,
        pyramid: TexturePyramid,
        iterations: Int,
        offset: Float
    ) throws -> MTLTexture {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RenderError.commandBufferCreationFailed
        }

        commandBuffer.label = "Dual Kawase Blur"

        // Phase 1: Initial downsample from source to pyramid[1]
        try renderPass(
            commandBuffer: commandBuffer,
            source: source,
            target: pyramid[1],
            pipeline: try pipelineCache.getDownsamplePipeline(),
            offset: offset
        )

        // Phase 2: Downsample loop - pyramid[i] -> pyramid[i+1]
        for i in 1..<iterations {
            try renderPass(
                commandBuffer: commandBuffer,
                source: pyramid[i],
                target: pyramid[i + 1],
                pipeline: try pipelineCache.getDownsamplePipeline(),
                offset: offset
            )
        }

        // Phase 3: Upsample loop - pyramid[i] -> pyramid[i-1]
        for i in stride(from: iterations, through: 1, by: -1) {
            try renderPass(
                commandBuffer: commandBuffer,
                source: pyramid[i],
                target: pyramid[i - 1],
                pipeline: try pipelineCache.getUpsamplePipeline(),
                offset: offset
            )
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Result is in pyramid[0]
        return pyramid[0]
    }

    /// Execute single render pass
    private func renderPass(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        target: MTLTexture,
        pipeline: MTLRenderPipelineState,
        offset: Float
    ) throws {
        // Create render pass descriptor
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = target
        renderPassDescriptor.colorAttachments[0].loadAction = .dontCare
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw RenderError.renderPassCreationFailed
        }

        encoder.label = "Blur Pass"

        // Set pipeline state
        encoder.setRenderPipelineState(pipeline)

        // Set viewport to target texture size
        encoder.setViewport(MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(target.width),
            height: Double(target.height),
            znear: 0.0,
            zfar: 1.0
        ))

        // Set uniforms
        var uniforms = BlurUniforms(
            textureWidth: Float(target.width),
            textureHeight: Float(target.height),
            offsetValue: offset
        )

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlurUniforms>.size, index: 0)
        encoder.setFragmentTexture(source, index: 0)

        // Draw full-screen quad
        quad.draw(encoder: encoder)

        encoder.endEncoding()
    }
}
