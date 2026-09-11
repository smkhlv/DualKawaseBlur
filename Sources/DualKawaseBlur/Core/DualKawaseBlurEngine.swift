import Metal
import UIKit

public final class DualKawaseBlurEngine: Sendable {
    private let context: MetalContext
    private let renderer: DualKawaseBlurRenderer
    private let textureConverter: ImageTextureConverter
    private let scheduler: StillImageScheduler

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        let context = try MetalContext(device: device)
        self.context = context
        renderer = try DualKawaseBlurRenderer(context: context)
        textureConverter = ImageTextureConverter(device: context.device)
        scheduler = StillImageScheduler()
    }

    @MainActor
    public func blur(
        _ image: UIImage,
        configuration: BlurConfiguration = .init()
    ) async throws -> UIImage {
        let prepared: PreparedImage
        do {
            prepared = try textureConverter.prepare(image)
        } catch {
            throw DualKawaseBlurError.unsupportedTexture
        }
        do {
            try configuration.validate(forWidth: prepared.width, height: prepared.height)
        } catch {
            throw DualKawaseBlurError.invalidConfiguration
        }

        let context = context
        let renderer = renderer
        let converter = textureConverter
        let pixels: ImagePixels
        do {
            pixels = try await scheduler.schedule {
                try Task.checkCancellation()
                let source = try converter.texture(from: prepared)
                let destination = try Self.makeDestinationTexture(
                    device: context.device,
                    width: prepared.width,
                    height: prepared.height,
                    pixelFormat: source.pixelFormat
                )
                let readback = try converter.makeReadbackTexture(
                    width: prepared.width,
                    height: prepared.height,
                    pixelFormat: source.pixelFormat
                )
                let workspace = try TexturePyramid(
                    device: context.device,
                    width: prepared.width,
                    height: prepared.height,
                    pixelFormat: source.pixelFormat,
                    configuration: configuration
                )
                guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
                    throw DualKawaseBlurError.commandBufferCreationFailed
                }
                try renderer.encode(
                    source: source,
                    destination: destination,
                    workspace: workspace,
                    configuration: configuration,
                    into: commandBuffer
                )
                try converter.encodeReadback(from: destination, to: readback, into: commandBuffer)
                try Task.checkCancellation()
                try await Self.commitAndAwaitCompletion(commandBuffer)
                try Task.checkCancellation()
                return try converter.pixels(from: readback, metadata: prepared)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DualKawaseBlurError {
            throw error
        } catch let error as ImageTextureConverter.ConversionError {
            throw Self.publicError(for: error)
        }
        try Task.checkCancellation()
        do {
            return try textureConverter.image(from: pixels)
        } catch let error as ImageTextureConverter.ConversionError {
            throw Self.publicError(for: error)
        }
    }

    public func encode(
        source: MTLTexture,
        destination: MTLTexture,
        configuration: BlurConfiguration,
        into commandBuffer: MTLCommandBuffer
    ) throws {
        guard source.device === context.device,
              destination.device === context.device,
              commandBuffer.device === context.device,
              commandBuffer.status == .notEnqueued || commandBuffer.status == .enqueued else {
            throw DualKawaseBlurError.unsupportedTexture
        }
        let workspace = try TexturePyramid(
            device: context.device,
            width: source.width,
            height: source.height,
            pixelFormat: source.pixelFormat,
            configuration: configuration
        )
        let lifetime = WorkspaceLifetime(workspace)
        commandBuffer.addCompletedHandler { _ in lifetime.retainUntilHere() }
        try renderer.encode(
            source: source,
            destination: destination,
            workspace: workspace,
            configuration: configuration,
            into: commandBuffer
        )
    }

    private static func makeDestinationTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw DualKawaseBlurError.textureAllocationFailed
        }
        return texture
    }

    private static func commitAndAwaitCompletion(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if buffer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: DualKawaseBlurError.gpuExecutionFailed)
                }
            }
            commandBuffer.commit()
        }
    }

    static func publicError(
        for error: ImageTextureConverter.ConversionError
    ) -> DualKawaseBlurError {
        switch error {
        case .cgImageCreationFailed, .invalidTextureFormat:
            .unsupportedTexture
        case .textureCreationFailed:
            .textureAllocationFailed
        case .bufferCreationFailed:
            .commandBufferCreationFailed
        }
    }
}

/// The command buffer owns this immutable retention token through completion.
private final class WorkspaceLifetime: @unchecked Sendable {
    private let workspace: TexturePyramid

    init(_ workspace: TexturePyramid) { self.workspace = workspace }

    func retainUntilHere() {
        withExtendedLifetime(workspace) {}
    }
}
