import Metal

@_spi(Benchmark)
public final class BenchmarkBlurEncoder {
    private let renderer: DualKawaseBlurRenderer
    private let workspace: TexturePyramid
    private let configuration: BlurConfiguration

    public init(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        configuration: BlurConfiguration
    ) throws {
        let context = try MetalContext(device: device)
        renderer = try DualKawaseBlurRenderer(context: context)
        workspace = try TexturePyramid(
            device: device,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            configuration: configuration
        )
        self.configuration = configuration
    }

    public func encode(
        source: MTLTexture,
        destination: MTLTexture,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        try renderer.encode(
            source: source,
            destination: destination,
            workspace: workspace,
            configuration: configuration,
            into: commandBuffer
        )
    }
}
