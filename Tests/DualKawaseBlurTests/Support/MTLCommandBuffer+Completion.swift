import Metal

extension MTLCommandBuffer {
    func commitAndWaitForCompletion() async -> MTLCommandBufferStatus {
        await withCheckedContinuation { continuation in
            addCompletedHandler { commandBuffer in
                continuation.resume(returning: commandBuffer.status)
            }
            commit()
        }
    }
}
