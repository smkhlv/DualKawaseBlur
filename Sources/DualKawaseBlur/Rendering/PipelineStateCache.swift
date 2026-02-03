import Metal

/// Caches compiled pipeline states for efficient reuse
class PipelineStateCache {
    private let device: MTLDevice
    private let library: MTLLibrary

    private var downsamplePipeline: MTLRenderPipelineState?
    private var upsamplePipeline: MTLRenderPipelineState?
    private var copyPipeline: MTLRenderPipelineState?

    enum PipelineError: Error {
        case functionNotFound(String)
        case pipelineCreationFailed(Error)
    }

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    /// Get or create downsample pipeline state
    func getDownsamplePipeline() throws -> MTLRenderPipelineState {
        if let pipeline = downsamplePipeline {
            return pipeline
        }

        let pipeline = try createPipeline(
            vertexFunction: "vertexShader",
            fragmentFunction: "downsampleFragment"
        )

        downsamplePipeline = pipeline
        return pipeline
    }

    /// Get or create upsample pipeline state
    func getUpsamplePipeline() throws -> MTLRenderPipelineState {
        if let pipeline = upsamplePipeline {
            return pipeline
        }

        let pipeline = try createPipeline(
            vertexFunction: "vertexShader",
            fragmentFunction: "upsampleFragment"
        )

        upsamplePipeline = pipeline
        return pipeline
    }

    /// Get or create copy pipeline state (for rendering to drawable)
    func getCopyPipeline() throws -> MTLRenderPipelineState {
        if let pipeline = copyPipeline {
            return pipeline
        }

        let pipeline = try createPipeline(
            vertexFunction: "vertexShader",
            fragmentFunction: "copyFragment",
            pixelFormat: .bgra8Unorm
        )

        copyPipeline = pipeline
        return pipeline
    }

    /// Create pipeline state with given shader functions
    private func createPipeline(
        vertexFunction: String,
        fragmentFunction: String,
        pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    ) throws -> MTLRenderPipelineState {
        guard let vertexFunc = library.makeFunction(name: vertexFunction) else {
            throw PipelineError.functionNotFound(vertexFunction)
        }

        guard let fragmentFunc = library.makeFunction(name: fragmentFunction) else {
            throw PipelineError.functionNotFound(fragmentFunction)
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc

        // Configure vertex input layout
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        descriptor.vertexDescriptor = vertexDescriptor

        // Color attachment format
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw PipelineError.pipelineCreationFailed(error)
        }
    }

    /// Clear cached pipelines (for memory management)
    func clear() {
        downsamplePipeline = nil
        upsamplePipeline = nil
        copyPipeline = nil
    }
}
