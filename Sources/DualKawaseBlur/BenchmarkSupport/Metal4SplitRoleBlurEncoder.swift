// The iOS Simulator SDK ships stub MTL4 headers, so this encoder exists on devices and macOS only.
#if !targetEnvironment(simulator)
import Metal

/// Metal 4 twin of `SplitRoleBlurEncoder`: same plan, shaders and per-pass uniforms, encoded into an
/// `MTL4CommandBuffer`. Uniforms live in one buffer baked at init and every pass owns an argument
/// table, so per frame only the source binding and the final attachment change.
/// Metal 4 has no hazard tracking: explicit barriers order the stages and, through queue barriers,
/// intermediate reuse by later command buffers on the same queue.
/// Not concurrently reusable: its intermediate textures belong to one in-flight sequence.
@available(iOS 26.0, macOS 26.0, *)
@_spi(Benchmark)
public final class Metal4SplitRoleBlurEncoder {
    private struct RenderPass {
        let pipeline: MTLRenderPipelineState
        let descriptor: MTL4RenderPassDescriptor
        let table: MTL4ArgumentTable
        /// Earlier queue work this pass's fragments wait for.
        let waitsFor: MTLStages
    }

    private struct Dispatch {
        let pipeline: MTLComputePipelineState
        let table: MTL4ArgumentTable
        let grid: MTLSize
    }

    private enum Step {
        case render(RenderPass)
        case compute([Dispatch])
    }

    private let device: MTLDevice
    private let width: Int
    private let height: Int
    // Internal for invariant tests; never writable through the benchmark SPI.
    let intermediateTextures: [MTLTexture]
    private let uniforms: MTLBuffer
    private let steps: [Step]
    /// Bound per frame: the first pass samples the source, the last one renders into the destination.
    private let sourceTable: MTL4ArgumentTable
    private let finalDescriptor: MTL4RenderPassDescriptor

    public init(device: MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat,
                configuration: BlurConfiguration) throws {
        guard device.supportsFamily(.metal4) else { throw DualKawaseBlurError.metalUnavailable }
        let layout = try TexturePyramidLayout(width: width, height: height, configuration: configuration)
        guard pixelFormat == .bgra8Unorm else { throw DualKawaseBlurError.unsupportedTexture }
        guard layout.levels.count >= 2 else { throw DualKawaseBlurError.invalidConfiguration }
        let context = try MetalContext(device: device)
        func renderPipeline(_ name: String) throws -> MTLRenderPipelineState {
            try RedistributedRender.pipeline(name, context: context, device: device, pixelFormat: pixelFormat)
        }
        let downsample = try renderPipeline("downsampleFragment4Tap443")
        let restore = try renderPipeline("upsampleFragment4Tap443")
        let final = try renderPipeline("upsampleFragment1TapRedistributed443")
        let computeDownsample = try SplitRoleBlurEncoder.computePipeline("downsampleCompute4Tap",
                                                                         context: context, device: device)
        let computeUpsample = try SplitRoleBlurEncoder.computePipeline("upsampleCompute4Tap",
                                                                       context: context, device: device)
        let intermediates = try SplitRoleBlurEncoder.makeIntermediates(layout: layout, device: device,
                                                                       pixelFormat: pixelFormat)
        let plan = SplitRoleBlurEncoder.plan(levelCount: layout.levels.count)

        // One 16-byte slot per pass, in encode order; compute passes use the first 8 bytes.
        let offset = configuration.offset
        var values: [SIMD4<Float>] = []
        for stage in plan {
            switch stage {
            case let .renderDownsample(_, to):
                values.append(RedistributedRender.uniforms(offset: offset, width: layout.levels[to].width,
                    height: layout.levels[to].height, fullWidth: width, fullHeight: height,
                    finalPass: false, compensate: false))
            case let .compute(passes):
                for pass in passes {
                    let to = switch pass { case let .downsample(_, to), let .upsample(_, to): to }
                    let step = RedistributedRender.step(offset: offset, width: layout.levels[to].width,
                                                        height: layout.levels[to].height)
                    values.append(SIMD4<Float>(step.x, step.y, 0, 0))
                }
            case let .renderRestore(_, to):
                values.append(RedistributedRender.uniforms(offset: offset, width: layout.levels[to].width,
                    height: layout.levels[to].height, fullWidth: width, fullHeight: height,
                    finalPass: false, compensate: true))
            case .renderFinal:
                values.append(RedistributedRender.uniforms(offset: offset, width: width, height: height,
                    fullWidth: width, fullHeight: height, finalPass: true, compensate: false))
            }
        }
        let stride = MemoryLayout<SIMD4<Float>>.stride
        guard let uniforms = values.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { throw DualKawaseBlurError.textureAllocationFailed }

        var slot = 0
        func table(textures: Int) throws -> MTL4ArgumentTable {
            let descriptor = MTL4ArgumentTableDescriptor()
            descriptor.maxBufferBindCount = 1
            descriptor.maxTextureBindCount = textures
            let table: MTL4ArgumentTable
            do { table = try device.makeArgumentTable(descriptor: descriptor) }
            catch { throw DualKawaseBlurError.pipelineCreationFailed }
            table.setAddress(uniforms.gpuAddress + UInt64(slot * stride), index: 0)
            slot += 1
            return table
        }
        func renderPass(_ pipeline: MTLRenderPipelineState, from source: MTLTexture?, to target: MTLTexture?,
                        waitsFor: MTLStages) throws -> RenderPass {
            let descriptor = MTL4RenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            let table = try table(textures: 1)
            if let source { table.setTexture(source.gpuResourceID, index: 0) }
            return RenderPass(pipeline: pipeline, descriptor: descriptor, table: table, waitsFor: waitsFor)
        }

        var steps: [Step] = []
        for stage in plan {
            switch stage {
            case let .renderDownsample(_, to):
                // WAR on level 0 against the previous sequence's compute read and restore/final passes.
                steps.append(.render(try renderPass(downsample, from: nil, to: intermediates[to],
                                                    waitsFor: [.fragment, .dispatch])))
            case let .compute(passes):
                steps.append(.compute(try passes.map { pass in
                    let (pipeline, from, to) = switch pass {
                    case let .downsample(from, to): (computeDownsample, from, to)
                    case let .upsample(from, to): (computeUpsample, from, to)
                    }
                    let table = try table(textures: 2)
                    table.setTexture(intermediates[from].gpuResourceID, index: 0)
                    table.setTexture(intermediates[to].gpuResourceID, index: 1)
                    return Dispatch(pipeline: pipeline, table: table, grid: MTLSize(
                        width: intermediates[to].width, height: intermediates[to].height, depth: 1))
                }))
            case let .renderRestore(from, to):
                // RAW on the last compute-written level; WAR on level 0, which the first dispatch read.
                steps.append(.render(try renderPass(restore, from: intermediates[from], to: intermediates[to],
                                                    waitsFor: .dispatch)))
            case let .renderFinal(from):
                // RAW on level 0, written by the restore pass.
                steps.append(.render(try renderPass(final, from: intermediates[from], to: nil,
                                                    waitsFor: .fragment)))
            }
        }
        precondition(slot == values.count, "every pass binds exactly one uniforms slot, in plan order")
        guard case let .render(first) = steps.first, case let .render(last) = steps.last else {
            throw DualKawaseBlurError.invalidConfiguration
        }
        sourceTable = first.table
        finalDescriptor = last.descriptor
        self.steps = steps
        self.uniforms = uniforms
        intermediateTextures = intermediates
        self.device = device
        self.width = width
        self.height = height
    }

    /// Residency for the intermediates, the uniforms and the caller's ring of sources and
    /// destinations. Build it once at setup and attach it to the queue or command buffers.
    public func makeResidencySet(including textures: [MTLTexture]) throws -> MTLResidencySet {
        let descriptor = MTLResidencySetDescriptor()
        descriptor.initialCapacity = intermediateTextures.count + textures.count + 1
        let set: MTLResidencySet
        do { set = try device.makeResidencySet(descriptor: descriptor) }
        catch { throw DualKawaseBlurError.metalUnavailable }
        set.addAllocations(intermediateTextures + textures + [uniforms])
        set.commit()
        return set
    }

    /// `source` and `destination` must be in a residency set the command buffer or its queue uses.
    ///
    /// Caller contract:
    /// - The caller owns hazards on `source` and `destination`. The barriers here exist for this
    ///   encoder's stages and intermediates; whatever writes `source` (a blit, another queue) and
    ///   whatever reads `destination` must be ordered by the caller's own barriers, fences or events.
    /// - MTL4 command buffers do not retain resources: keep this encoder, `source` and `destination`
    ///   alive until the commit's feedback handler (or a later queue signal) reports completion.
    public func encode(source: MTLTexture, destination: MTLTexture,
                       into commandBuffer: MTL4CommandBuffer) throws {
        try RedistributedRender.validate(source: source, destination: destination,
            bufferDevice: commandBuffer.device, intermediates: intermediateTextures, device: device,
            width: width, height: height)
        // The tables and descriptor are snapshotted when encoded, so rebinding never touches queued work.
        sourceTable.setTexture(source.gpuResourceID, index: 0)
        finalDescriptor.colorAttachments[0].texture = destination
        defer { finalDescriptor.colorAttachments[0].texture = nil }
        for step in steps {
            switch step {
            case let .render(pass): try encodeRender(pass, into: commandBuffer)
            case let .compute(dispatches): try encodeCompute(dispatches, into: commandBuffer)
            }
        }
    }

    private func encodeRender(_ pass: RenderPass, into commandBuffer: MTL4CommandBuffer) throws {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass.descriptor) else {
            throw DualKawaseBlurError.commandBufferCreationFailed
        }
        defer { encoder.endEncoding() }
        // Attachment loads/stores and texture reads both run in the fragment stage.
        encoder.barrier(afterQueueStages: pass.waitsFor, beforeStages: .fragment, visibilityOptions: .device)
        encoder.setRenderPipelineState(pass.pipeline)
        encoder.setArgumentTable(pass.table, stages: .fragment)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func encodeCompute(_ dispatches: [Dispatch], into commandBuffer: MTL4CommandBuffer) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DualKawaseBlurError.commandBufferCreationFailed
        }
        defer { encoder.endEncoding() }
        // RAW on level 0 from the downsample pass; WAR on the levels the previous sequence's
        // restore pass read and its dispatches wrote.
        encoder.barrier(afterQueueStages: [.fragment, .dispatch], beforeStages: .dispatch,
                        visibilityOptions: .device)
        for (index, dispatch) in dispatches.enumerated() {
            if index > 0 {
                // Each dispatch reads the level the previous one wrote.
                encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch,
                                visibilityOptions: .device)
            }
            encoder.setComputePipelineState(dispatch.pipeline)
            encoder.setArgumentTable(dispatch.table)
            encoder.dispatchThreads(threadsPerGrid: dispatch.grid,
                                    threadsPerThreadgroup: SplitRoleBlurEncoder.threadgroupSize)
        }
    }
}
#endif
