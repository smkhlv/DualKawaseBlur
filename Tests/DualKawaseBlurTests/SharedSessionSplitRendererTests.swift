import Foundation
import Metal
import Testing
@_spi(Benchmark) @testable import DualKawaseBlur

private let width = 37
private let height = 53

@Test @MainActor func sessionOutputMatchesSplitEncoderDirectly() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let configuration = BlurConfiguration(iterations: 3, offset: 5)
    let source = MetalBlurFrameSource()
    let session = try SharedMetalBlurSession(source: source, configuration: configuration, device: device)
    defer { session.finish() }
    let texture = try TestTexture.patterned(device: device, width: width, height: height)

    source.publish(MetalBlurFrame(texture: texture))
    session.renderLatest()
    let actual = try await SessionReadback.nextOutput(of: session, after: 0).bytes

    let expected = try await standaloneLevelZeroBytes(device: device, source: texture, configuration: configuration)
    #expect(actual == expected)
}

@Test @MainActor func offsetChangeRebuildsSplitWorkspaces() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let session = try SharedMetalBlurSession(
        source: source, configuration: BlurConfiguration(iterations: 3, offset: 5), device: device)
    defer { session.finish() }
    let texture = try TestTexture.patterned(device: device, width: width, height: height)

    source.publish(MetalBlurFrame(texture: texture))
    session.renderLatest()
    let first = try await SessionReadback.nextOutput(of: session, after: 0)
    let firstEncoders = session.workspaces.map(\.blur)  // held so freed addresses can't alias

    let changed = BlurConfiguration(iterations: 3, offset: 2)
    session.update(configuration: changed)
    source.publish(MetalBlurFrame(texture: texture))
    session.renderLatest()
    let second = try await SessionReadback.nextOutput(of: session, after: first.sequence)

    #expect(second.bytes == (try await standaloneLevelZeroBytes(device: device, source: texture, configuration: changed)))
    #expect(second.bytes != first.bytes)
    #expect(Set(session.workspaces.map { ObjectIdentifier($0.blur) })
        .isDisjoint(with: firstEncoders.map { ObjectIdentifier($0) }))
}

@Test @MainActor func sessionUsesOneSplitEncoderPerSlot() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let session = try SharedMetalBlurSession(
        source: source, configuration: BlurConfiguration(iterations: 3, offset: 5), device: device)
    defer { session.finish() }

    source.publish(MetalBlurFrame(texture: try TestTexture.patterned(device: device, width: width, height: height)))
    session.renderLatest()
    _ = try await SessionReadback.nextOutput(of: session, after: 0)

    let workspaces = session.workspaces
    #expect(workspaces.count == 3)
    #expect(Set(workspaces.map { ObjectIdentifier($0.blur) }).count == 3)
    let intermediates = workspaces.flatMap { $0.blur.intermediateTextures.map { ObjectIdentifier($0) } }
    #expect(intermediates.count == 9)
    #expect(Set(intermediates).count == 9)
}

/// The published half-resolution level a standalone encoder produces for `source`.
private func standaloneLevelZeroBytes(device: MTLDevice, source: MTLTexture,
                                      configuration: BlurConfiguration) async throws -> Data {
    let split = try SplitRoleBlurEncoder(device: device, width: width, height: height,
        pixelFormat: .bgra8Unorm, configuration: configuration)
    let queue = try #require(device.makeCommandQueue())
    let buffer = try #require(queue.makeCommandBuffer())
    let levelZero = try split.encodeThroughLevelZero(source: source, into: buffer)
    let readable = try TestTexture.empty(device: device, width: levelZero.width, height: levelZero.height,
                                         usage: .shaderRead)
    let blit = try #require(buffer.makeBlitCommandEncoder())
    blit.copy(from: levelZero, to: readable)
    blit.endEncoding()
    #expect(await buffer.commitAndWaitForCompletion() == .completed)
    return TestTexture.bytes(readable)
}

enum SessionReadback {
    struct Output {
        let sequence: UInt64
        let bytes: Data
    }

    /// Waits for a published level 0 newer than `sequence`, then copies it out of its private texture.
    @MainActor
    static func nextOutput(of session: SharedMetalBlurSession, after sequence: UInt64) async throws -> Output {
        var lease = session.acquireLatestOutput()
        for _ in 0..<500 where (lease?.sequence ?? 0) <= sequence {
            lease?.release()
            try await Task.sleep(nanoseconds: 10_000_000)
            lease = session.acquireLatestOutput()
        }
        let latest = try #require(lease)
        defer { latest.release() }
        #expect(latest.sequence > sequence)
        let bytes = try copyOut(latest.resource.published, session: session)
        return Output(sequence: latest.sequence, bytes: bytes)
    }

    @MainActor
    static func copyOut(_ output: MTLTexture, session: SharedMetalBlurSession) throws -> Data {
        let readable = try TestTexture.empty(device: session.device, width: output.width, height: output.height,
                                             usage: .shaderRead)
        let buffer = try #require(session.makePresentationCommandBuffer())
        let blit = try #require(buffer.makeBlitCommandEncoder())
        blit.copy(from: output, to: readable)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)
        return TestTexture.bytes(readable)
    }
}
