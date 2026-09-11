import Metal
import Testing
import UIKit
@testable import DualKawaseBlur

@Test func rendererEncodesWithoutOwningCommit() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let context = try MetalContext(device: device)
    let renderer = try DualKawaseBlurRenderer(context: context)
    let configuration = BlurConfiguration(iterations: 2, offset: 1)
    let workspace = try TexturePyramid(
        device: device,
        width: 16,
        height: 16,
        pixelFormat: .bgra8Unorm,
        configuration: configuration
    )
    let source = try TestTexture.impulse(device: device, width: 16, height: 16)
    let destination = try TestTexture.empty(device: device, width: 16, height: 16)
    let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())

    try renderer.encode(
        source: source,
        destination: destination,
        workspace: workspace,
        configuration: configuration,
        into: commandBuffer
    )

    #expect(commandBuffer.status == .notEnqueued)
    #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
    #expect(try TestTexture.nonZeroPixelCount(destination) > 1)
}

@Test func rendererRejectsWorkspaceForDifferentInputDimensions() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let context = try MetalContext(device: device)
    let renderer = try DualKawaseBlurRenderer(context: context)
    let configuration = BlurConfiguration(iterations: 2, offset: 1)
    let workspace = try TexturePyramid(
        device: device,
        width: 32,
        height: 32,
        pixelFormat: .bgra8Unorm,
        configuration: configuration
    )
    let source = try TestTexture.impulse(device: device, width: 16, height: 16)
    let destination = try TestTexture.empty(device: device, width: 16, height: 16)
    let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())

    #expect(throws: DualKawaseBlurError.unsupportedTexture) {
        try renderer.encode(
            source: source,
            destination: destination,
            workspace: workspace,
            configuration: configuration,
            into: commandBuffer
        )
    }
}

@Test func workspaceMapsInvalidConfigurationToPublicError() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }

    #expect(throws: DualKawaseBlurError.invalidConfiguration) {
        _ = try TexturePyramid(
            device: device,
            width: 16,
            height: 16,
            pixelFormat: .bgra8Unorm,
            configuration: BlurConfiguration(iterations: 0, offset: 1)
        )
    }
}

@Test func rendererRejectsUnsupportedTextureShapeAndUsage() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let context = try MetalContext(device: device)
    let renderer = try DualKawaseBlurRenderer(context: context)
    let configuration = BlurConfiguration(iterations: 2, offset: 1)
    let workspace = try TexturePyramid(
        device: device,
        width: 16,
        height: 16,
        pixelFormat: .bgra8Unorm,
        configuration: configuration
    )
    let destination = try TestTexture.empty(device: device, width: 16, height: 16)

    let cubeDescriptor = MTLTextureDescriptor.textureCubeDescriptor(
        pixelFormat: .bgra8Unorm,
        size: 16,
        mipmapped: false
    )
    cubeDescriptor.usage = .shaderRead
    let cube = try #require(device.makeTexture(descriptor: cubeDescriptor))
    let cubeCommandBuffer = try #require(context.commandQueue.makeCommandBuffer())
    #expect(throws: DualKawaseBlurError.unsupportedTexture) {
        try renderer.encode(
            source: cube,
            destination: destination,
            workspace: workspace,
            configuration: configuration,
            into: cubeCommandBuffer
        )
    }

    let source = try TestTexture.impulse(device: device, width: 16, height: 16)
    let readOnlyDestination = try TestTexture.empty(
        device: device,
        width: 16,
        height: 16,
        usage: .shaderRead
    )
    let usageCommandBuffer = try #require(context.commandQueue.makeCommandBuffer())
    #expect(throws: DualKawaseBlurError.unsupportedTexture) {
        try renderer.encode(
            source: source,
            destination: readOnlyDestination,
            workspace: workspace,
            configuration: configuration,
            into: usageCommandBuffer
        )
    }
}

@Test func rendererScalesAndConvertsBetweenSupportedOutputFormats() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let context = try MetalContext(device: device)
    let renderer = try DualKawaseBlurRenderer(context: context)
    let configuration = BlurConfiguration(iterations: 2, offset: 1)
    let workspace = try TexturePyramid(
        device: device,
        width: 16,
        height: 16,
        pixelFormat: .bgra8Unorm_srgb,
        configuration: configuration
    )
    let source = try TestTexture.impulse(
        device: device,
        width: 16,
        height: 16,
        pixelFormat: .bgra8Unorm_srgb
    )
    let destination = try TestTexture.empty(
        device: device,
        width: 24,
        height: 20,
        pixelFormat: .bgra8Unorm
    )
    let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())

    try renderer.encode(
        source: source,
        destination: destination,
        workspace: workspace,
        configuration: configuration,
        into: commandBuffer
    )

    #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
    #expect(try TestTexture.nonZeroPixelCount(destination) > 1)
}

@Test func rendererAcceptsAnEnqueuedCommandBuffer() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let context = try MetalContext(device: device)
    let renderer = try DualKawaseBlurRenderer(context: context)
    let configuration = BlurConfiguration(iterations: 1, offset: 1)
    let workspace = try TexturePyramid(
        device: device,
        width: 8,
        height: 8,
        pixelFormat: .bgra8Unorm,
        configuration: configuration
    )
    let source = try TestTexture.impulse(device: device, width: 8, height: 8)
    let destination = try TestTexture.empty(device: device, width: 8, height: 8)
    let commandBuffer = try #require(context.commandQueue.makeCommandBuffer())
    commandBuffer.enqueue()

    try renderer.encode(
        source: source,
        destination: destination,
        workspace: workspace,
        configuration: configuration,
        into: commandBuffer
    )

    #expect(await commandBuffer.commitAndWaitForCompletion() == .completed)
}

@Test func rendererHasCheckedSendableContract() throws {
    func requireSendable<T: Sendable>(_: T.Type) {}
    requireSendable(DualKawaseBlurRenderer.self)
}

@MainActor
@Test func imageConverterProducesRendererSupportedBGRAFormat() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
        UIColor.systemPink.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    let texture = try ImageTextureConverter(device: device).texture(from: image)

    #expect(texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb)
}
