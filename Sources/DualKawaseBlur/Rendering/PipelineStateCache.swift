import Metal

/// Immutable render pipelines, safe to reuse while encoding on multiple threads.
final class PipelineStateCache: Sendable {
    private let downsamplePipelines: [MTLPixelFormat: MTLRenderPipelineState]
    private let upsamplePipelines: [MTLPixelFormat: MTLRenderPipelineState]
    private let copyPipelines: [MTLPixelFormat: MTLRenderPipelineState]

    init(device: MTLDevice, library: MTLLibrary) throws {
        let formats: [MTLPixelFormat] = [.bgra8Unorm, .bgra8Unorm_srgb]
        downsamplePipelines = try Self.makePipelines(
            device: device,
            library: library,
            fragmentFunctionName: "downsampleFragment",
            formats: formats
        )
        upsamplePipelines = try Self.makePipelines(
            device: device,
            library: library,
            fragmentFunctionName: "upsampleFragment",
            formats: formats
        )
        copyPipelines = try Self.makePipelines(
            device: device,
            library: library,
            fragmentFunctionName: "copyFragment",
            formats: formats
        )
    }

    func downsamplePipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        try pipeline(in: downsamplePipelines, for: format)
    }

    func upsamplePipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        try pipeline(in: upsamplePipelines, for: format)
    }

    func copyPipeline(for format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        try pipeline(in: copyPipelines, for: format)
    }

    func getDownsamplePipeline() throws -> MTLRenderPipelineState {
        try downsamplePipeline(for: .bgra8Unorm_srgb)
    }

    func getUpsamplePipeline() throws -> MTLRenderPipelineState {
        try upsamplePipeline(for: .bgra8Unorm_srgb)
    }

    func getCopyPipeline() throws -> MTLRenderPipelineState {
        try copyPipeline(for: .bgra8Unorm)
    }

    private func pipeline(
        in pipelines: [MTLPixelFormat: MTLRenderPipelineState],
        for format: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        guard let pipeline = pipelines[format] else {
            throw DualKawaseBlurError.unsupportedTexture
        }
        return pipeline
    }

    private static func makePipelines(
        device: MTLDevice,
        library: MTLLibrary,
        fragmentFunctionName: String,
        formats: [MTLPixelFormat]
    ) throws -> [MTLPixelFormat: MTLRenderPipelineState] {
        guard
            let vertexFunction = library.makeFunction(name: "vertexShader"),
            let fragmentFunction = library.makeFunction(name: fragmentFunctionName)
        else {
            throw DualKawaseBlurError.pipelineCreationFailed
        }

        return try Dictionary(uniqueKeysWithValues: formats.map { format in
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = format

            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
            vertexDescriptor.layouts[0].stepFunction = .perVertex
            descriptor.vertexDescriptor = vertexDescriptor

            do {
                return (format, try device.makeRenderPipelineState(descriptor: descriptor))
            } catch {
                throw DualKawaseBlurError.pipelineCreationFailed
            }
        })
    }
}
