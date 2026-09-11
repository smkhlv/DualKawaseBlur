import Foundation
import Metal

/// Immutable references to Metal objects whose APIs are documented as thread-safe.
final class MetalContext: Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let pipelines: PipelineStateCache

    init(device: MTLDevice?) throws {
        guard let device else {
            throw DualKawaseBlurError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw DualKawaseBlurError.metalUnavailable
        }
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
            throw DualKawaseBlurError.libraryLoadingFailed
        }

        self.device = device
        self.commandQueue = commandQueue
        self.library = library
        pipelines = try PipelineStateCache(device: device, library: library)
    }

    convenience init() throws {
        try self.init(device: MTLCreateSystemDefaultDevice())
    }
}
