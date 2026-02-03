import UIKit
import Metal
import CoreGraphics

/// High-level API for applying Dual Kawase Blur to images
public class DualKawaseBlurEngine {
    private let context: MetalContext
    private let renderer: BlurRenderer
    private let textureConverter: ImageTextureConverter
    private let pyramid: TexturePyramid

    public enum BlurError: Error {
        case metalInitializationFailed(Error)
        case invalidParameters
        case textureConversionFailed(Error)
        case renderingFailed(Error)
    }

    /// Initialize blur engine with Metal context
    public init() throws {
        do {
            self.context = try MetalContext()
            self.textureConverter = ImageTextureConverter(device: context.device)
            self.pyramid = TexturePyramid(device: context.device)
            self.renderer = try BlurRenderer(
                device: context.device,
                commandQueue: context.commandQueue,
                library: context.library
            )
        } catch {
            throw BlurError.metalInitializationFailed(error)
        }
    }

    /// Apply Dual Kawase Blur to image
    /// - Parameters:
    ///   - image: Source image to blur
    ///   - iterations: Number of blur iterations (1-5). Higher = stronger blur
    ///   - offset: Blur radius multiplier (1.0-5.0). Higher = wider blur
    /// - Returns: Blurred image, or nil if processing failed
    public func blur(image: UIImage, iterations: Int, offset: Float) -> UIImage? {
        // Validate parameters
        guard iterations >= 1 && iterations <= 5 else {
            print("Error: iterations must be 1-5")
            return nil
        }

        guard offset >= 1.0 && offset <= 5.0 else {
            print("Error: offset must be 1.0-5.0")
            return nil
        }

        do {
            // Convert input image to texture
            let sourceTexture = try textureConverter.texture(from: image)

            // Create or reuse pyramid
            let imageSize = CGSize(width: sourceTexture.width, height: sourceTexture.height)
            try pyramid.createPyramid(size: imageSize, iterations: iterations)

            // Execute blur
            let resultTexture = try renderer.executeBlur(
                source: sourceTexture,
                pyramid: pyramid,
                iterations: iterations,
                offset: offset
            )

            // Convert result back to UIImage
            return try textureConverter.image(from: resultTexture)

        } catch let error as BlurError {
            print("Blur error: \(error)")
            return nil
        } catch {
            print("Unexpected error: \(error)")
            return nil
        }
    }

    /// Clear cached resources (call on memory warning)
    public func clearCache() {
        pyramid.clear()
    }
}
