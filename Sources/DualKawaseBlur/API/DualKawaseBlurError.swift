import Foundation

public enum DualKawaseBlurError: Error, LocalizedError, Sendable, Equatable {
    case metalUnavailable
    case libraryLoadingFailed
    case pipelineCreationFailed
    case invalidConfiguration
    case unsupportedTexture
    case textureAllocationFailed
    case commandBufferCreationFailed
    case gpuExecutionFailed

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "Metal is unavailable on this device."
        case .libraryLoadingFailed:
            "The Dual Kawase shader library could not be loaded."
        case .pipelineCreationFailed:
            "The Dual Kawase render pipeline could not be created."
        case .invalidConfiguration:
            "The blur configuration is invalid for the input dimensions."
        case .unsupportedTexture:
            "The input texture is not supported."
        case .textureAllocationFailed:
            "A texture required for the blur operation could not be allocated."
        case .commandBufferCreationFailed:
            "A Metal command buffer could not be created."
        case .gpuExecutionFailed:
            "The GPU failed to complete the blur operation."
        }
    }
}
