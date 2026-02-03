import Metal
import Foundation

/// Central Metal context managing device, queue, and shader library
class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    enum MetalError: Error {
        case deviceNotFound
        case commandQueueCreationFailed
        case libraryNotFound
    }

    init() throws {
        // Get default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalError.deviceNotFound
        }
        self.device = device

        // Create command queue
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue

        // Load Metal library from correct bundle (SPM module or app bundle)
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: MetalContext.self)
        #endif

        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            throw MetalError.libraryNotFound
        }
        self.library = library
    }

    /// Create a command buffer from the queue
    func makeCommandBuffer() -> MTLCommandBuffer? {
        return commandQueue.makeCommandBuffer()
    }
}
