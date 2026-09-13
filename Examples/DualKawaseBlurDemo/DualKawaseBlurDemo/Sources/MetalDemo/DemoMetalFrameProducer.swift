import MetalKit
import SwiftUI
import Synchronization
import DualKawaseBlur

@MainActor
struct DemoMetalFrameProducer: UIViewRepresentable {
    let source: MetalBlurFrameSource

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.delegate = context.coordinator
        view.device = context.coordinator.device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    func makeCoordinator() -> DemoMetalRenderer {
        DemoMetalRenderer(source: source)
    }
}

@MainActor
final class DemoMetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice

    private let source: MetalBlurFrameSource
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let readinessEvent: MTLSharedEvent
    private let texturePool: DemoTexturePool
    private let startTime = CACurrentMediaTime()
    private var readinessValue: UInt64 = 0

    init(source: MetalBlurFrameSource) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let readinessEvent = device.makeSharedEvent()
        else {
            fatalError("Metal is unavailable")
        }

        self.device = device
        self.source = source
        self.commandQueue = commandQueue
        self.readinessEvent = readinessEvent
        texturePool = DemoTexturePool(device: device, capacity: 3)
        pipeline = Self.makePipeline(device: device)
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let textureLease = texturePool.tryAcquire(
                width: Int(view.drawableSize.width),
                height: Int(view.drawableSize.height)
            ),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = textureLease.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = view.clearColor

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            textureLease.release()
            return
        }

        var time = Float(CACurrentMediaTime() - startTime)
        renderEncoder.setRenderPipelineState(pipeline)
        renderEncoder.setFragmentBytes(&time, length: MemoryLayout<Float>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        renderEncoder.endEncoding()

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            textureLease.release()
            return
        }
        blitEncoder.copy(
            from: textureLease.texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(
                width: textureLease.texture.width,
                height: textureLease.texture.height,
                depth: 1
            ),
            to: drawable.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        readinessValue &+= 1
        let publishedValue = readinessValue
        commandBuffer.encodeSignalEvent(readinessEvent, value: publishedValue)
        commandBuffer.present(drawable)
        commandBuffer.commit()

        source.publish(
            MetalBlurFrame(
                texture: textureLease.texture,
                readiness: .sharedEvent(readinessEvent, value: publishedValue),
                onConsumed: { textureLease.release() }
            )
        )
    }

    private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState {
        let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct DemoVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex DemoVertexOut demoVertex(uint vertexID [[vertex_id]]) {
            const float2 positions[] = {
                float2(-1.0, -1.0),
                float2( 3.0, -1.0),
                float2(-1.0,  3.0)
            };
            DemoVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = positions[vertexID] * 0.5 + 0.5;
            return out;
        }

        fragment float4 demoFragment(DemoVertexOut in [[stage_in]],
                                     constant float &time [[buffer(0)]]) {
            float3 top = float3(0.08, 0.18, 0.50);
            float3 bottom = float3(0.58, 0.08, 0.42);
            float3 color = mix(bottom, top, clamp(in.uv.y, 0.0, 1.0));

            float2 firstCenter = float2(
                0.5 + 0.28 * sin(time * 0.73),
                0.5 + 0.24 * cos(time * 0.91)
            );
            float2 secondCenter = float2(
                0.5 + 0.32 * cos(time * 0.57),
                0.5 + 0.20 * sin(time * 0.83)
            );
            float firstGlow = 1.0 - smoothstep(0.04, 0.30, distance(in.uv, firstCenter));
            float secondGlow = 1.0 - smoothstep(0.03, 0.26, distance(in.uv, secondCenter));
            color += firstGlow * float3(0.95, 0.38, 0.10);
            color += secondGlow * float3(0.10, 0.76, 0.82);
            return float4(color, 1.0);
        }
        """

        do {
            let library = try device.makeLibrary(source: shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "demoVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "demoFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Unable to build demo Metal pipeline: \(error)")
        }
    }
}

nonisolated private final class DemoTexturePool: Sendable {
    private struct Size: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    private struct Slot: Sendable {
        let id: Int
        let texture: DemoTextureReference
    }

    private final class Generation: @unchecked Sendable {
        var id: UInt64
        let size: Size
        var slots: [Slot?]

        init(id: UInt64, size: Size, textures: [MTLTexture]) {
            self.id = id
            self.size = size
            slots = textures.enumerated().map {
                Slot(id: $0.offset, texture: DemoTextureReference($0.element))
            }
        }
    }

    private struct State {
        var nextGenerationID: UInt64 = 0
        var current: Generation?
    }

    private enum Acquisition {
        case acquired(Slot, generation: UInt64)
        case unavailable
        case resize
    }

    private enum Installation {
        case installed(Generation?)
        case alreadyCurrent
    }

    private let device: DemoDeviceReference
    private let capacity: Int
    private let state = Mutex(State())

    init(device: MTLDevice, capacity: Int) {
        self.device = DemoDeviceReference(device)
        self.capacity = capacity
    }

    func tryAcquire(width: Int, height: Int) -> DemoTextureLease? {
        guard width > 0, height > 0 else { return nil }
        let size = Size(width: width, height: height)
        guard let acquisition = acquireExisting(size: size) else { return nil }
        if case let .acquired(slot, generation) = acquisition {
            return makeLease(slot: slot, generation: generation)
        }
        guard case .resize = acquisition,
              let replacement = makeGeneration(size: size),
              let installation = state.withLockIfAvailable({ state -> Installation in
                  guard state.current?.size != size else { return .alreadyCurrent }
                  state.nextGenerationID &+= 1
                  replacement.id = state.nextGenerationID
                  let retired = state.current
                  state.current = replacement
                  return .installed(retired)
              }) else { return nil }

        if case let .installed(retired) = installation {
            withExtendedLifetime(retired) {}
        }
        guard case let .acquired(slot, generation) = acquireExisting(size: size) else { return nil }
        return makeLease(slot: slot, generation: generation)
    }

    private func acquireExisting(size: Size) -> Acquisition? {
        state.withLockIfAvailable { state in
            guard let generation = state.current, generation.size == size else { return .resize }
            guard let index = generation.slots.lastIndex(where: { $0 != nil }) else {
                return .unavailable
            }
            let slot = generation.slots[index]!
            generation.slots[index] = nil
            return .acquired(slot, generation: generation.id)
        }
    }

    private func makeLease(slot: Slot, generation: UInt64) -> DemoTextureLease {
        DemoTextureLease(texture: slot.texture.value) { [weak self] in
            self?.returnSlot(slot, generation: generation)
        }
    }

    private func makeGeneration(size: Size) -> Generation? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        var textures: [MTLTexture] = []
        textures.reserveCapacity(capacity)
        for _ in 0..<capacity {
            guard let texture = device.value.makeTexture(descriptor: descriptor) else { return nil }
            textures.append(texture)
        }
        return Generation(id: 0, size: size, textures: textures)
    }

    private func returnSlot(_ slot: Slot, generation: UInt64) {
        state.withLock { state in
            guard
                let current = state.current,
                current.id == generation,
                current.slots.indices.contains(slot.id),
                current.slots[slot.id] == nil
            else { return }
            current.slots[slot.id] = slot
        }
    }
}

nonisolated private final class DemoTextureLease: Sendable {
    private let reference: DemoTextureReference
    private let action: Mutex<(@Sendable () -> Void)?>

    var texture: MTLTexture { reference.value }

    init(texture: MTLTexture, onRelease: @escaping @Sendable () -> Void) {
        reference = DemoTextureReference(texture)
        action = Mutex(onRelease)
    }

    func release() {
        let callback = action.withLock { action in
            defer { action = nil }
            return action
        }
        callback?()
    }

    deinit { release() }
}

nonisolated private struct DemoTextureReference: @unchecked Sendable {
    let value: MTLTexture
    init(_ value: MTLTexture) { self.value = value }
}

nonisolated private struct DemoDeviceReference: @unchecked Sendable {
    let value: MTLDevice
    init(_ value: MTLDevice) { self.value = value }
}
