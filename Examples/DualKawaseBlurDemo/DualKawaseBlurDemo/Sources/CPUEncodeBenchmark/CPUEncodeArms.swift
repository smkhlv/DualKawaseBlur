import Metal
import MetalPerformanceShaders
import QuartzCore
@_spi(Benchmark) import DualKawaseBlur

/// Measured paths. O and S are the all-render and split encoders; L is MPS Gaussian with
/// `allowReducedPrecision`, a reused kernel, clamp edges and a private usage-3 output, exactly
/// as selected by the 2026-10-10 confirmation; S4 is `Metal4SplitRoleBlurEncoder`, the Metal 4 split encoder.
enum CPUEncodeArm: String, CaseIterable, Codable, Sendable {
    case O, S, S4, L

    enum Failure: Error { case allocation, s4NotCompiled, s4Unsupported }

    static let configuration = BlurConfiguration(iterations: 5, offset: 5)
    static let sigma: Float = 92.087890625

    /// True only in builds with `CPU_ENCODE_S4` set; only those compile the S4 arm in.
    static var s4Compiled: Bool {
        #if CPU_ENCODE_S4
        true
        #else
        false
        #endif
    }

    /// Private full-size output: usage 5 for the render-final encoders, usage 3 for MPS.
    var outputUsage: MTLTextureUsage { self == .L ? [.shaderRead, .shaderWrite] : [.shaderRead, .renderTarget] }

    /// `textures` is every source and destination the submitter will see (S4 residency).
    func makeSubmitter(device: MTLDevice, queue: MTLCommandQueue, textures: [MTLTexture]) throws -> CPUEncodeSubmitter {
        let width = CPUEncodeCorpus.width, height = CPUEncodeCorpus.height
        switch self {
        case .O:
            let encoder = try RedistributedAllRenderBlurEncoder(device: device, width: width, height: height,
                pixelFormat: .bgra8Unorm, configuration: Self.configuration)
            return ClassicSubmitter(queue: queue) { try encoder.encode(source: $0, destination: $1, into: $2) }
        case .S:
            let encoder = try SplitRoleBlurEncoder(device: device, width: width, height: height,
                pixelFormat: .bgra8Unorm, configuration: Self.configuration)
            return ClassicSubmitter(queue: queue) { try encoder.encode(source: $0, destination: $1, into: $2) }
        case .L:
            let gaussian = MPSImageGaussianBlur(device: device, sigma: Self.sigma)
            gaussian.edgeMode = .clamp
            gaussian.options = .allowReducedPrecision
            return ClassicSubmitter(queue: queue) { gaussian.encode(commandBuffer: $2, sourceTexture: $0, destinationTexture: $1) }
        case .S4:
            // The simulator SDK has no MTL4 types; S4 exists only in device builds.
            #if targetEnvironment(simulator)
            throw Failure.s4Unsupported
            #else
            guard #available(iOS 26.0, *) else { throw Failure.s4Unsupported }
            guard let encoder = try Self.makeMetal4Split(device: device) else { throw Failure.s4NotCompiled }
            return try Metal4Submitter(device: device, encoder: encoder, textures: textures)
            #endif
        }
    }

    #if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private static func makeMetal4Split(device: MTLDevice) throws -> (any Metal4BlurEncoding)? {
        #if CPU_ENCODE_S4
        guard device.supportsFamily(.metal4) else { throw Failure.s4Unsupported }
        return try Metal4SplitRoleBlurEncoder(device: device, width: CPUEncodeCorpus.width,
            height: CPUEncodeCorpus.height, pixelFormat: .bgra8Unorm, configuration: configuration)
        #else
        return nil
        #endif
    }
    #endif
}

/// Measured paths of `PATH_LEVEL_PROTOCOL.md` (`path-level-v2`). Each arm is a whole path: its blur,
/// then the presenters' opaque composite (`.unit` mapping, `baseColor`) into a private full-size render
/// target, in one command buffer. LC is v1's L blur and SC v1's S blur (with its full-size final pass);
/// SH is S's half-size level 0, the production blur since Task 2, composited directly.
enum PathLevelArm: String, CaseIterable, Sendable {
    case LC, SC, SH

    static let protocolID = "path-level-v2"
    /// RGBA, exact in Float and JSON; the host audits it against `cpu_encode.COMPOSITE_BASE_COLOR`.
    static let baseColor = SIMD4<Float>(0.25, 0.5, 0.75, 1)
    static let compositeMapping = BenchmarkOpaqueCompositeEncoder.mappingName
    /// The composite target: private, full size, `[.renderTarget]` = usage 4.
    static let compositeUsage: MTLTextureUsage = [.renderTarget]

    /// Each blur writes a private full-size output (LC usage 3, SC usage 5), except SH: its composite
    /// samples S's own half-size level 0.
    func makePath(device: MTLDevice, composite: BenchmarkOpaqueCompositeEncoder) throws -> PathLevelPath {
        func split() throws -> SplitRoleBlurEncoder {
            try SplitRoleBlurEncoder(device: device, width: CPUEncodeCorpus.width, height: CPUEncodeCorpus.height,
                pixelFormat: .bgra8Unorm, configuration: CPUEncodeArm.configuration)
        }
        switch self {
        case .LC:
            // Exactly v1's L configuration and output.
            let output = try CPUEncodeTextures.texture(device, .private, [.shaderRead, .shaderWrite])
            let gaussian = MPSImageGaussianBlur(device: device, sigma: CPUEncodeArm.sigma)
            gaussian.edgeMode = .clamp
            gaussian.options = .allowReducedPrecision
            return PathLevelPath(blurOutput: output, composite: composite) {
                gaussian.encode(commandBuffer: $1, sourceTexture: $0, destinationTexture: output)
                return output
            }
        case .SC:
            let output = try CPUEncodeTextures.texture(device, .private, [.shaderRead, .renderTarget])
            let encoder = try split()
            return PathLevelPath(blurOutput: output, composite: composite) {
                try encoder.encode(source: $0, destination: output, into: $1)
                return output
            }
        case .SH:
            let encoder = try split()
            return PathLevelPath(blurOutput: nil, composite: composite) {
                try encoder.encodeThroughLevelZero(source: $0, into: $1)
            }
        }
    }
}

/// What a path-level report records about one arm's textures; the host compares it with
/// `cpu_encode.path_output`. Nil fields are omitted (SH has no blur output).
struct PathOutput: Encodable {
    var blurOutputTextureUsage: UInt?
    var blurOutputStorageMode: UInt?
    let compositeSourceWidth: Int
    let compositeSourceHeight: Int
    let compositeTextureUsage: UInt
    let compositeStorageMode: UInt
}

/// One path-level arm: `encode` is the whole CPU endpoint (the blur encoder call, then the composite).
final class PathLevelPath {
    private let blurOutput: MTLTexture?
    private let blur: (MTLTexture, MTLCommandBuffer) throws -> MTLTexture
    private let composite: BenchmarkOpaqueCompositeEncoder
    /// The texture the composite sampled, kept once for the report (the same texture on every row).
    private var compositeSource: MTLTexture?

    init(blurOutput: MTLTexture?, composite: BenchmarkOpaqueCompositeEncoder,
         blur: @escaping (MTLTexture, MTLCommandBuffer) throws -> MTLTexture) {
        self.blurOutput = blurOutput
        self.blur = blur
        self.composite = composite
    }

    func encode(source: MTLTexture, target: MTLTexture, into buffer: MTLCommandBuffer) throws {
        let blurred = try blur(source, buffer)
        try composite.encode(source: blurred, destination: target, baseColor: PathLevelArm.baseColor, into: buffer)
        if compositeSource == nil { compositeSource = blurred }
    }

    /// One drained buffer per row holding blur + composite; the target is the submitter's destination.
    func makeSubmitter(queue: MTLCommandQueue) -> CPUEncodeSubmitter {
        ClassicSubmitter(queue: queue) { [self] in try encode(source: $0, target: $1, into: $2) }
    }

    /// Nil until the first encode has shown which texture the composite samples.
    func record(target: MTLTexture) -> PathOutput? {
        guard let compositeSource else { return nil }
        return PathOutput(blurOutputTextureUsage: blurOutput?.usage.rawValue,
            blurOutputStorageMode: blurOutput?.storageMode.rawValue, compositeSourceWidth: compositeSource.width,
            compositeSourceHeight: compositeSource.height, compositeTextureUsage: target.usage.rawValue,
            compositeStorageMode: target.storageMode.rawValue)
    }
}

/// Host-time stamps of one blur. `encode*` brackets only the encoder call (the CPU endpoint);
/// `submit*` adds buffer creation/begin/end/commit and is descriptive only, never gated.
struct CPUEncodeTiming: Encodable {
    let submitStart: Double
    let encodeStart: Double
    let encodeEnd: Double
    let submitEnd: Double
    let gpuStart: Double
    let gpuEnd: Double
    let gpuSucceeded: Bool
}

/// Encodes and drains one blur per call; no call overlaps another.
protocol CPUEncodeSubmitter: AnyObject {
    func submit(source: MTLTexture, destination: MTLTexture) async throws -> CPUEncodeTiming
}

final class ClassicSubmitter: CPUEncodeSubmitter {
    private let queue: MTLCommandQueue
    private let encode: (MTLTexture, MTLTexture, MTLCommandBuffer) throws -> Void

    init(queue: MTLCommandQueue, encode: @escaping (MTLTexture, MTLTexture, MTLCommandBuffer) throws -> Void) {
        self.queue = queue
        self.encode = encode
    }

    func submit(source: MTLTexture, destination: MTLTexture) async throws -> CPUEncodeTiming {
        let submitStart = CACurrentMediaTime()
        guard let buffer = queue.makeCommandBuffer() else { throw CPUEncodeArm.Failure.allocation }
        let encodeStart = CACurrentMediaTime()
        try encode(source, destination, buffer)
        let encodeEnd = CACurrentMediaTime()
        var submitEnd = 0.0
        // A committed buffer cannot be cancelled: drain it exactly once.
        let status = await withCheckedContinuation { continuation in
            buffer.addCompletedHandler { continuation.resume(returning: $0.status) }
            buffer.commit()
            submitEnd = CACurrentMediaTime()
        }
        return CPUEncodeTiming(submitStart: submitStart, encodeStart: encodeStart, encodeEnd: encodeEnd,
            submitEnd: submitEnd, gpuStart: buffer.gpuStartTime, gpuEnd: buffer.gpuEndTime,
            gpuSucceeded: status == .completed)
    }
}

#if !targetEnvironment(simulator)
/// The part of `Metal4SplitRoleBlurEncoder`'s API the submitter uses; the conformance is the only S4-specific line.
@available(iOS 26.0, *)
protocol Metal4BlurEncoding: AnyObject {
    func makeResidencySet(including textures: [MTLTexture]) throws -> MTLResidencySet
    func encode(source: MTLTexture, destination: MTLTexture, into commandBuffer: MTL4CommandBuffer) throws
}

#if CPU_ENCODE_S4
@available(iOS 26.0, *)
extension Metal4SplitRoleBlurEncoder: Metal4BlurEncoding {}
#endif

/// One reused MTL4 command buffer and allocator; GPU times come from commit feedback.
@available(iOS 26.0, *)
final class Metal4Submitter: CPUEncodeSubmitter {
    private let queue: MTL4CommandQueue
    private let allocator: MTL4CommandAllocator
    private let commandBuffer: MTL4CommandBuffer
    private let encoder: any Metal4BlurEncoding

    init(device: MTLDevice, encoder: any Metal4BlurEncoding, textures: [MTLTexture]) throws {
        guard let queue = device.makeMTL4CommandQueue(), let allocator = device.makeCommandAllocator(),
              let commandBuffer = device.makeCommandBuffer() else { throw CPUEncodeArm.Failure.allocation }
        // Built once at setup, never per frame.
        let residency = try encoder.makeResidencySet(including: textures)
        residency.requestResidency()
        queue.addResidencySet(residency)
        self.queue = queue
        self.allocator = allocator
        self.commandBuffer = commandBuffer
        self.encoder = encoder
    }

    func submit(source: MTLTexture, destination: MTLTexture) async throws -> CPUEncodeTiming {
        let submitStart = CACurrentMediaTime()
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)
        let encodeStart = CACurrentMediaTime()
        do {
            try encoder.encode(source: source, destination: destination, into: commandBuffer)
        } catch {
            commandBuffer.endCommandBuffer()
            throw error
        }
        let encodeEnd = CACurrentMediaTime()
        commandBuffer.endCommandBuffer()
        var submitEnd = 0.0
        let queue = queue, commandBuffer = commandBuffer
        let feedback = await withCheckedContinuation { continuation in
            let options = MTL4CommitOptions()
            options.addFeedbackHandler { feedback in
                continuation.resume(returning: (feedback.gpuStartTime, feedback.gpuEndTime, feedback.error == nil))
            }
            queue.commit([commandBuffer], options: options)
            submitEnd = CACurrentMediaTime()
        }
        return CPUEncodeTiming(submitStart: submitStart, encodeStart: encodeStart, encodeEnd: encodeEnd,
            submitEnd: submitEnd, gpuStart: feedback.0, gpuEnd: feedback.1, gpuSucceeded: feedback.2)
    }
}

#endif
