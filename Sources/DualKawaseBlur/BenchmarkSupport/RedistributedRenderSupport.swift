import Metal

/// Render-pass pieces shared by the all-render and split redistributed 4/4/1 encoders,
/// so the uniforms layout and penultimate-step routing exist once.
enum RedistributedRender {
    static func pipeline(_ name: String, context: MetalContext, device: MTLDevice,
                         pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        guard let vertex = context.library.makeFunction(name: "fullscreenTriangle443"),
              let fragment = context.library.makeFunction(name: name) else {
            throw DualKawaseBlurError.pipelineCreationFailed
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        do { return try device.makeRenderPipelineState(descriptor: descriptor) }
        catch { throw DualKawaseBlurError.pipelineCreationFailed }
    }

    static func validate(source: MTLTexture, destination: MTLTexture, buffer: MTLCommandBuffer,
                         intermediates: [MTLTexture], device: MTLDevice,
                         width: Int, height: Int) throws {
        try validate(source: source, destination: destination, bufferDevice: buffer.device,
                     intermediates: intermediates, device: device, width: width, height: height)
    }

    /// Command-buffer-agnostic form, shared with the Metal 4 encoder.
    static func validate(source: MTLTexture, destination: MTLTexture, bufferDevice: MTLDevice,
                         intermediates: [MTLTexture], device: MTLDevice,
                         width: Int, height: Int) throws {
        try validate(source: source, bufferDevice: bufferDevice, intermediates: intermediates,
                     device: device, width: width, height: height)
        guard source !== destination,
              !intermediates.contains(where: { $0 === destination }),
              destination.width == width, destination.height == height,
              destination.pixelFormat == .bgra8Unorm,
              destination.device === device,
              destination.textureType == .type2D,
              destination.sampleCount == 1,
              destination.usage.isEmpty || destination.usage.contains(.renderTarget) else {
            throw DualKawaseBlurError.unsupportedTexture
        }
    }

    /// The source-side checks alone, for passes that stop at an intermediate level.
    static func validate(source: MTLTexture, buffer: MTLCommandBuffer, intermediates: [MTLTexture],
                         device: MTLDevice, width: Int, height: Int) throws {
        try validate(source: source, bufferDevice: buffer.device, intermediates: intermediates,
                     device: device, width: width, height: height)
    }

    private static func validate(source: MTLTexture, bufferDevice: MTLDevice, intermediates: [MTLTexture],
                                 device: MTLDevice, width: Int, height: Int) throws {
        guard !intermediates.contains(where: { $0 === source }),
              source.width == width, source.height == height,
              source.pixelFormat == .bgra8Unorm,
              source.device === device, bufferDevice === device,
              source.textureType == .type2D,
              source.sampleCount == 1,
              source.usage.isEmpty || source.usage.contains(.shaderRead) else {
            throw DualKawaseBlurError.unsupportedTexture
        }
    }

    /// `fullWidth`/`fullHeight` are the input size, used only by the compensated restore step.
    static func render(_ source: MTLTexture, to destination: MTLTexture,
                       pipeline: MTLRenderPipelineState, offset: Float,
                       fullWidth: Int, fullHeight: Int, finalPass: Bool = false,
                       compensate: Bool = false, into buffer: MTLCommandBuffer) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw DualKawaseBlurError.pipelineCreationFailed
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        var uniforms = Self.uniforms(offset: offset, width: destination.width, height: destination.height,
            fullWidth: fullWidth, fullHeight: fullHeight, finalPass: finalPass, compensate: compensate)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // Default tracked hazards plus distinct render encoders order read/write reuse.
    }

    /// Fragment uniforms for a pass writing `width`×`height`: step in xy, size (or 1/size when final) in zw.
    static func uniforms(offset: Float, width: Int, height: Int, fullWidth: Int, fullHeight: Int,
                         finalPass: Bool, compensate: Bool) -> SIMD4<Float> {
        let w = Float(width), h = Float(height)
        let step = compensate
            ? RedistributedAllRenderBlurEncoder.redistributedPenultimateStep(offset: offset,
                width: width, height: height, fullWidth: fullWidth, fullHeight: fullHeight)
            : Self.step(offset: offset, width: width, height: height)
        return SIMD4<Float>(step.x, step.y, finalPass ? 1 / w : w, finalPass ? 1 / h : h)
    }

    /// Uncompensated sample step for a pass writing `width`×`height` (render and compute alike).
    static func step(offset: Float, width: Int, height: Int) -> SIMD2<Float> {
        SIMD2<Float>(offset * 0.5 / Float(width), offset * 0.5 / Float(height))
    }
}
