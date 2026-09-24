import Metal
import MetalPerformanceShaders

/// Benchmark-only fast candidate: two filtered reductions followed by one
/// bilinear full-resolution copy. It deliberately does not change the public
/// Dual Kawase renderer until visual and device timing gates have passed.
@_spi(Benchmark)
public final class FastDualKawaseBlurEncoder {
    public let reductionLevelCount: Int

    private let context: MetalContext
    private let renderer: DualKawaseBlurRenderer
    private let reductionTextures: [MTLTexture]
    private let inputWidth: Int
    private let inputHeight: Int
    private let pixelFormat: MTLPixelFormat
    private let offset: Float

    public init(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        configuration: BlurConfiguration
    ) throws {
        try configuration.validate(forWidth: width, height: height)
        context = try MetalContext(device: device)
        renderer = try DualKawaseBlurRenderer(context: context)
        let plan = try ReducedResolutionPlan(
            width: width,
            height: height,
            levels: min(2, configuration.iterations)
        )
        reductionTextures = try Self.makeReductionTextures(
            device: device,
            pixelFormat: pixelFormat,
            plan: plan
        )
        inputWidth = width
        inputHeight = height
        self.pixelFormat = pixelFormat
        offset = configuration.offset
        self.reductionLevelCount = plan.levels.count
    }

    public func encode(
        source: MTLTexture,
        destination: MTLTexture,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        try validate(source: source, destination: destination, commandBuffer: commandBuffer)
        var current = source
        for texture in reductionTextures {
            try renderer.encodeDownsample(
                source: current,
                destination: texture,
                offset: offset,
                into: commandBuffer
            )
            current = texture
        }
        try renderer.encodeCopy(source: current, destination: destination, into: commandBuffer)
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
              source.device === context.device,
              destination.device === context.device,
              commandBuffer.device === context.device else {
            throw DualKawaseBlurError.unsupportedTexture
        }
    }

    fileprivate static func makeReductionTextures(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        plan: ReducedResolutionPlan
    ) throws -> [MTLTexture] {
        guard pixelFormat == .bgra8Unorm || pixelFormat == .bgra8Unorm_srgb else {
            throw DualKawaseBlurError.unsupportedTexture
        }
        return try plan.levels.map { level in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: level.width,
                height: level.height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw DualKawaseBlurError.textureAllocationFailed
            }
            return texture
        }
    }
}

/// Benchmark-only control: the same filtered reduction and final bilinear copy
/// as `FastDualKawaseBlurEncoder`, with MPS Gaussian executed at low resolution.
@_spi(Benchmark)
public final class ReducedResolutionMPSGaussianEncoder {
    public let reductionLevelCount: Int

    private let context: MetalContext
    private let renderer: DualKawaseBlurRenderer
    private let reductionTextures: [MTLTexture]
    private let gaussianDestination: MTLTexture
    private let gaussian: MPSImageGaussianBlur
    private let inputWidth: Int
    private let inputHeight: Int
    private let pixelFormat: MTLPixelFormat
    private let reductionOffset: Float

    public init(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        sigma: Float,
        reductionOffset: Float,
        reductionLevelCount: Int
    ) throws {
        guard sigma.isFinite, sigma > 0, reductionOffset.isFinite, reductionOffset > 0, reductionLevelCount > 0 else {
            throw DualKawaseBlurError.invalidConfiguration
        }
        context = try MetalContext(device: device)
        renderer = try DualKawaseBlurRenderer(context: context)
        let plan = try ReducedResolutionPlan(width: width, height: height, levels: reductionLevelCount)
        reductionTextures = try FastDualKawaseBlurEncoder.makeReductionTextures(
            device: device,
            pixelFormat: pixelFormat,
            plan: plan
        )
        guard let lowestResolution = reductionTextures.last else {
            throw DualKawaseBlurError.textureAllocationFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: lowestResolution.width,
            height: lowestResolution.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let gaussianDestination = device.makeTexture(descriptor: descriptor) else {
            throw DualKawaseBlurError.textureAllocationFailed
        }
        self.gaussianDestination = gaussianDestination
        gaussian = MPSImageGaussianBlur(device: device, sigma: sigma)
        gaussian.edgeMode = .clamp
        inputWidth = width
        inputHeight = height
        self.pixelFormat = pixelFormat
        self.reductionOffset = reductionOffset
        self.reductionLevelCount = plan.levels.count
    }

    public func encode(
        source: MTLTexture,
        destination: MTLTexture,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        guard source.width == inputWidth,
              source.height == inputHeight,
              destination.width == inputWidth,
              destination.height == inputHeight,
              source.pixelFormat == pixelFormat,
              destination.pixelFormat == pixelFormat,
              source.device === context.device,
              destination.device === context.device,
              commandBuffer.device === context.device else {
            throw DualKawaseBlurError.unsupportedTexture
        }
        var current = source
        for texture in reductionTextures {
            try renderer.encodeDownsample(
                source: current,
                destination: texture,
                offset: reductionOffset,
                into: commandBuffer
            )
            current = texture
        }
        gaussian.encode(
            commandBuffer: commandBuffer,
            sourceTexture: current,
            destinationTexture: gaussianDestination
        )
        try renderer.encodeCopy(
            source: gaussianDestination,
            destination: destination,
            into: commandBuffer
        )
    }
}
