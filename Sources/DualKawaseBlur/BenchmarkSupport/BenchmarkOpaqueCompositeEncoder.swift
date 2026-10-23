import Metal

/// The presenters' opaque composite for path-level benchmarks (`PATH_LEVEL_PROTOCOL.md`): it calls the
/// renderer's own `encodeOpaqueComposite` with the `.unit` mapping, so a benchmark path ends in exactly
/// the pass the presenters encode, minus the drawable. No shader or pass logic lives here.
@_spi(Benchmark)
public final class BenchmarkOpaqueCompositeEncoder {
    /// The mapping every call uses, as benchmark reports record it.
    public static let mappingName = "unit"

    private let renderer: DualKawaseBlurRenderer

    public init(device: MTLDevice) throws {
        renderer = try DualKawaseBlurRenderer(context: MetalContext(device: device))
    }

    /// Samples `source` over the whole `destination` (any source size: full resolution or level 0) and
    /// writes it, composited over the opaque `baseColor`, with alpha 1.
    public func encode(source: MTLTexture, destination: MTLTexture, baseColor: SIMD4<Float>,
                       into commandBuffer: MTLCommandBuffer) throws {
        try renderer.encodeOpaqueComposite(source: source, destination: destination, baseColor: baseColor,
                                           mapping: .unit, into: commandBuffer)
    }
}
