import Metal

final class DualKawaseBlurRenderer: Sendable {
    private let context: MetalContext
    private let quad: FullScreenQuad

    init(context: MetalContext) throws {
        self.context = context
        quad = try FullScreenQuad(device: context.device)
    }

    func encode(
        source: MTLTexture,
        destination: MTLTexture,
        workspace: TexturePyramid,
        configuration: BlurConfiguration,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        guard
            source.device === context.device,
            destination.device === context.device,
            commandBuffer.device === context.device,
            commandBuffer.status == .notEnqueued || commandBuffer.status == .enqueued,
            isSupportedPixelFormat(source.pixelFormat),
            isSupportedPixelFormat(destination.pixelFormat),
            isSupportedSource(source),
            isSupportedDestination(destination)
        else {
            throw DualKawaseBlurError.unsupportedTexture
        }

        let expectedLayout: TexturePyramidLayout
        do {
            expectedLayout = try TexturePyramidLayout(
                width: source.width,
                height: source.height,
                configuration: configuration
            )
        } catch {
            throw DualKawaseBlurError.invalidConfiguration
        }

        guard
            workspace.layout == expectedLayout,
            workspace.pixelFormat == source.pixelFormat,
            workspace.textures.count == expectedLayout.levels.count,
            zip(workspace.textures, expectedLayout.levels).allSatisfy({ texture, level in
                texture.device === context.device
                    && texture.width == level.width
                    && texture.height == level.height
                    && texture.pixelFormat == source.pixelFormat
                    && isSupportedWorkspaceTexture(texture)
            }),
            let firstTexture = workspace.textures.first
        else {
            throw DualKawaseBlurError.unsupportedTexture
        }

        try encodePass(
            source: source,
            destination: firstTexture,
            pipeline: context.pipelines.downsamplePipeline(for: firstTexture.pixelFormat),
            offset: configuration.offset,
            into: commandBuffer
        )

        for index in workspace.textures.indices.dropFirst() {
            try encodePass(
                source: workspace[index - 1],
                destination: workspace[index],
                pipeline: context.pipelines.downsamplePipeline(for: workspace[index].pixelFormat),
                offset: configuration.offset,
                into: commandBuffer
            )
        }

        for index in workspace.textures.indices.dropFirst().reversed() {
            try encodePass(
                source: workspace[index],
                destination: workspace[index - 1],
                pipeline: context.pipelines.upsamplePipeline(for: workspace[index - 1].pixelFormat),
                offset: configuration.offset,
                into: commandBuffer
            )
        }

        try encodePass(
            source: firstTexture,
            destination: destination,
            pipeline: context.pipelines.upsamplePipeline(for: destination.pixelFormat),
            offset: configuration.offset,
            into: commandBuffer
        )
    }

    /// Encodes one filtered reduction for the benchmark-only reduced-resolution paths.
    func encodeDownsample(
        source: MTLTexture,
        destination: MTLTexture,
        offset: Float,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        try validatePass(source: source, destination: destination, commandBuffer: commandBuffer)
        try encodePass(
            source: source,
            destination: destination,
            pipeline: context.pipelines.downsamplePipeline(for: destination.pixelFormat),
            offset: offset,
            into: commandBuffer
        )
    }

    /// Encodes a single bilinear sample at the output size.
    func encodeCopy(
        source: MTLTexture,
        destination: MTLTexture,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        try validatePass(source: source, destination: destination, commandBuffer: commandBuffer)
        try encodePass(
            source: source,
            destination: destination,
            pipeline: context.pipelines.copyPipeline(for: destination.pixelFormat),
            offset: 0,
            into: commandBuffer
        )
    }

    private func validatePass(
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard
            source.device === context.device,
            destination.device === context.device,
            commandBuffer.device === context.device,
            commandBuffer.status == .notEnqueued || commandBuffer.status == .enqueued,
            source.pixelFormat == destination.pixelFormat,
            isSupportedPixelFormat(source.pixelFormat),
            isSupportedSource(source),
            isSupportedDestination(destination)
        else {
            throw DualKawaseBlurError.unsupportedTexture
        }
    }

    private func encodePass(
        source: MTLTexture,
        destination: MTLTexture,
        pipeline: MTLRenderPipelineState,
        offset: Float,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw DualKawaseBlurError.commandBufferCreationFailed
        }
        defer { encoder.endEncoding() }

        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(
            MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(destination.width),
                height: Double(destination.height),
                znear: 0,
                zfar: 1
            )
        )
        var uniforms = BlurUniforms(
            textureWidth: Float(destination.width),
            textureHeight: Float(destination.height),
            offsetValue: offset
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<BlurUniforms>.size,
            index: 0
        )
        encoder.setFragmentTexture(source, index: 0)
        quad.draw(encoder: encoder)
    }

    private func isSupportedSource(_ texture: MTLTexture) -> Bool {
        texture.textureType == .type2D
            && texture.sampleCount == 1
            && texture.arrayLength == 1
            && texture.depth == 1
            && !texture.isFramebufferOnly
            && (texture.usage.isEmpty || texture.usage.contains(.shaderRead))
    }

    private func isSupportedPixelFormat(_ pixelFormat: MTLPixelFormat) -> Bool {
        pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb
    }

    private func isSupportedDestination(_ texture: MTLTexture) -> Bool {
        texture.textureType == .type2D
            && texture.sampleCount == 1
            && texture.arrayLength == 1
            && texture.depth == 1
            && (texture.usage.isEmpty || texture.usage.contains(.renderTarget))
    }

    private func isSupportedWorkspaceTexture(_ texture: MTLTexture) -> Bool {
        isSupportedSource(texture)
            && texture.usage.contains(.renderTarget)
    }
}
