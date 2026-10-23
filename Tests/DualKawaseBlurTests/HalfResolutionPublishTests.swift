import Foundation
import Metal
import Synchronization
import Testing
@_spi(Benchmark) @testable import DualKawaseBlur

private let production = BlurConfiguration(iterations: 5, offset: 5)
private let baseColor = SIMD4<Float>(0.2, 0.4, 0.6, 1)
private let offsetMapping = SharedBackgroundUVMapping(origin: [0.1, 0.05], scale: [0.8, 0.9])

/// Source content. The production blur flattens per-byte noise, so the structured case keeps
/// gradients and a hard edge alive through the blur, where the two composite paths can diverge.
enum SourceFixture: String, CaseIterable, Sendable {
    case noise, structured

    func texture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        switch self {
        case .noise:
            return try TestTexture.patterned(device: device, width: width, height: height)
        case .structured:
            // Horizontal red ramp, vertical blue ramp, and a hard green step at the middle column.
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    bytes[index] = UInt8(y * 255 / max(height - 1, 1))
                    bytes[index + 1] = x < width / 2 ? 40 : 215
                    bytes[index + 2] = UInt8(x * 255 / max(width - 1, 1))
                }
            }
            let texture = try TestTexture.empty(device: device, width: width, height: height)
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes, bytesPerRow: width * 4)
            return texture
        }
    }
}

/// One size x mapping x fixture combination (Swift Testing takes at most two argument collections).
struct CompositeCase: Sendable, CustomTestStringConvertible {
    let width: Int
    let height: Int
    let mapping: SharedBackgroundUVMapping
    let fixture: SourceFixture

    var testDescription: String { "\(fixture) \(width)x\(height) origin=\(mapping.origin) scale=\(mapping.scale)" }

    static let all: [CompositeCase] = [(37, 53), (1179, 2556)].flatMap { size in
        [SharedBackgroundUVMapping.unit, offsetMapping].flatMap { mapping in
            SourceFixture.allCases.map {
                CompositeCase(width: size.0, height: size.1, mapping: mapping, fixture: $0)
            }
        }
    }
}

@Test(arguments: CompositeCase.all)
func halfResolutionCompositeMatchesFullResolutionPath(testCase: CompositeCase) async throws {
    let (width, height, mapping, fixture) = (testCase.width, testCase.height, testCase.mapping, testCase.fixture)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let context = try MetalContext(device: device)
    let renderer = try DualKawaseBlurRenderer(context: context)
    let queue = try #require(device.makeCommandQueue())
    let encoder = try SplitRoleBlurEncoder(device: device, width: width, height: height,
        pixelFormat: .bgra8Unorm, configuration: production)
    let source = try fixture.texture(device: device, width: width, height: height)

    // Reference: the Task 1 path, a full-resolution final pass and then the composite.
    let fullResolution = try TestTexture.empty(device: device, width: width, height: height)
    let reference = try TestTexture.empty(device: device, width: width, height: height)
    var buffer = try #require(queue.makeCommandBuffer())
    try encoder.encode(source: source, destination: fullResolution, into: buffer)
    try renderer.encodeOpaqueComposite(source: fullResolution, destination: reference,
                                       baseColor: baseColor, mapping: mapping, into: buffer)
    #expect(await buffer.commitAndWaitForCompletion() == .completed)

    // Candidate: no final pass; the composite samples level 0 directly.
    var candidates: [Data] = []
    for _ in 0..<2 {
        let candidate = try TestTexture.empty(device: device, width: width, height: height)
        buffer = try #require(queue.makeCommandBuffer())
        let levelZero = try encoder.encodeThroughLevelZero(source: source, into: buffer)
        #expect(levelZero.width == width >> 1 && levelZero.height == height >> 1)
        try renderer.encodeOpaqueComposite(source: levelZero, destination: candidate,
                                           baseColor: baseColor, mapping: mapping, into: buffer)
        #expect(await buffer.commitAndWaitForCompletion() == .completed)
        candidates.append(TestTexture.bytes(candidate))
    }

    let expected = [UInt8](TestTexture.bytes(reference)), actual = [UInt8](candidates[0])
    #expect(expected.count == actual.count)
    let maxDifference = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(maxDifference <= 1, "\(testCase.testDescription): max channel difference \(maxDifference)")
    #expect(candidates[0] == candidates[1])
}

@Test @MainActor func frameInfoReportsSourceSizeNotPublishedTextureSize() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let session = try SharedMetalBlurSession(
        source: source, configuration: BlurConfiguration(iterations: 3, offset: 5), device: device)
    defer { session.finish() }

    source.publish(MetalBlurFrame(texture: try TestTexture.patterned(device: device, width: 37, height: 53)))
    session.renderLatest()
    _ = try await SessionReadback.nextOutput(of: session, after: 0)

    let info = try #require(session.latestCompletedFrameInfo)
    #expect(info.pixelWidth == 37)
    #expect(info.pixelHeight == 53)
    let latest = try #require(session.acquireLatestOutput())
    defer { latest.release() }
    #expect(latest.resource.published.width == 18)
    #expect(latest.resource.published.height == 26)
}

@Test @MainActor func publishedLevelZeroIsNotRewrittenWhileLeased() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let session = try SharedMetalBlurSession(
        source: source, configuration: BlurConfiguration(iterations: 3, offset: 5), device: device)
    defer { session.finish() }

    source.publish(MetalBlurFrame(texture: try TestTexture.patterned(device: device, width: 37, height: 53)))
    session.renderLatest()
    let first = try await SessionReadback.nextOutput(of: session, after: 0)
    let lease = try #require(session.acquireLatestOutput())
    #expect(lease.sequence == first.sequence)
    let leased = lease.resource.published
    let before = try SessionReadback.copyOut(leased, session: session)
    #expect(before == first.bytes)

    var sequence = first.sequence
    var latestBytes = before
    for phase in 1...3 {
        source.publish(MetalBlurFrame(
            texture: try TestTexture.patterned(device: device, width: 37, height: 53, phase: phase)))
        session.renderLatest()
        let next = try await SessionReadback.nextOutput(of: session, after: sequence)
        sequence = next.sequence
        latestBytes = next.bytes
    }

    // The newest frame went to another slot, and the leased level 0 kept its bytes.
    let newest = try #require(session.acquireLatestOutput())
    #expect(ObjectIdentifier(newest.resource.published) != ObjectIdentifier(leased))
    newest.release()
    #expect(latestBytes != before)
    #expect(try SessionReadback.copyOut(leased, session: session) == before)
    lease.release()
}

@Test @MainActor func sessionAllocatesNoFullResolutionOutput() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let session = try SharedMetalBlurSession(source: source, configuration: production, device: device)
    defer { session.finish() }

    source.publish(MetalBlurFrame(texture: try TestTexture.patterned(device: device, width: 64, height: 96)))
    session.renderLatest()
    _ = try await SessionReadback.nextOutput(of: session, after: 0)

    let workspaces = session.workspaces
    #expect(workspaces.count == 3)
    for workspace in workspaces {
        #expect(workspace.sourceWidth == 64 && workspace.sourceHeight == 96)
        let textures = workspace.blur.intermediateTextures + [workspace.published]
        for texture in textures {
            #expect(texture.width < workspace.sourceWidth && texture.height < workspace.sourceHeight)
        }
        // A workspace holds the encoder and sizes only; any texture field would be a full-size output.
        let stored = Mirror(reflecting: workspace).children.map { $0.value }
        #expect(!stored.contains { $0 is MTLTexture })
    }
}

@Test @MainActor func pipelineSetIsSharedAcrossSlotsAndRebuilds() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = MetalBlurFrameSource()
    let session = try SharedMetalBlurSession(
        source: source, configuration: BlurConfiguration(iterations: 3, offset: 5), device: device)
    defer { session.finish() }
    let texture = try TestTexture.patterned(device: device, width: 37, height: 53)

    source.publish(MetalBlurFrame(texture: texture))
    session.renderLatest()
    let first = try await SessionReadback.nextOutput(of: session, after: 0)
    let firstEncoders = session.workspaces.map(\.blur)
    let firstSet = Set(firstEncoders.flatMap(pipelineIdentities))
    #expect(firstSet.count == 5)
    for encoder in firstEncoders { #expect(Set(pipelineIdentities(encoder)) == firstSet) }

    // An offset change rebuilds the three workspaces; the compiled pipelines carry over.
    session.update(configuration: BlurConfiguration(iterations: 3, offset: 2))
    source.publish(MetalBlurFrame(texture: texture))
    session.renderLatest()
    _ = try await SessionReadback.nextOutput(of: session, after: first.sequence)

    let rebuilt = session.workspaces.map(\.blur)
    #expect(Set(rebuilt.map { ObjectIdentifier($0) }).isDisjoint(with: firstEncoders.map { ObjectIdentifier($0) }))
    for encoder in rebuilt { #expect(Set(pipelineIdentities(encoder)) == firstSet) }
}

private func pipelineIdentities(_ encoder: SplitRoleBlurEncoder) -> [ObjectIdentifier] {
    let pipelines = encoder.pipelines
    return [pipelines.downsample as AnyObject, pipelines.restore as AnyObject, pipelines.final as AnyObject,
            pipelines.computeDownsample as AnyObject, pipelines.computeUpsample as AnyObject]
        .map { ObjectIdentifier($0) }
}

@Test func workerReportsWorkspaceErrorWhenSplitCannotRun() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let cases: [(BlurConfiguration, MTLPixelFormat)] = [
        (BlurConfiguration(iterations: 1, offset: 5), .bgra8Unorm),  // one pyramid level
        (BlurConfiguration(iterations: 3, offset: 5), .rgba8Unorm),  // not a bgra8Unorm source
    ]
    for (configuration, format) in cases {
        let source = MetalBlurFrameSource()
        let outputs = SharedOutputFrames<SharedBlurWorkspace>(resources: [])
        let diagnostics = Mutex<[String]>([])
        let worker = SharedBlurEncodeWorker(
            source: source,
            context: try MetalContext(device: device),
            outputs: outputs,
            configuration: configuration,
            schedule: { _ in },
            onPublished: {},
            onDiagnostic: { message in diagnostics.withLock { $0.append(message) } }
        )
        let consumed = Mutex(0)
        let texture = try TestTexture.empty(device: device, width: 32, height: 32, pixelFormat: format,
                                            usage: .shaderRead)
        source.publish(MetalBlurFrame(texture: texture) { consumed.withLock { $0 += 1 } })

        worker.encodeLatest()

        let messages = diagnostics.withLock { $0 }
        #expect(messages.count == 1 && messages[0].hasPrefix("workspace error"), "\(messages)")
        #expect(consumed.withLock { $0 } == 1)
        #expect(outputs.acquireLatest() == nil)
        #expect(outputs.availableWriterCount == 0)  // no workspace was ever installed
    }
}
