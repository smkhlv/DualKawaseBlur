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

        // Get default library (compiled from .metal files in bundle)
        guard let library = device.makeDefaultLibrary() else {
            throw MetalError.libraryNotFound
        }
        self.library = library
    }

    /// Create a command buffer from the queue
    func makeCommandBuffer() -> MTLCommandBuffer? {
        return commandQueue.makeCommandBuffer()
    }
}
