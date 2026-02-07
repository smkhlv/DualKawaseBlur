import IOSurface
import Metal
import CoreGraphics
import UIKit

/// Zero-copy shared memory between CoreGraphics and Metal via IOSurface.
///
/// CGContext writes directly into IOSurface memory, and MTLTexture reads
/// from the same memory — no CPU-to-GPU copy needed.
final class SharedIOSurfaceTexture {

    let surface: IOSurfaceRef
    let texture: MTLTexture
    let cgContext: CGContext
    let width: Int
    let height: Int

    private let bytesPerRow: Int

    init?(device: MTLDevice, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }

        self.width = width
        self.height = height

        let bytesPerElement = 4
        let alignment = 16
        let rawBytesPerRow = width * bytesPerElement
        let alignedBytesPerRow = (rawBytesPerRow + alignment - 1) / alignment * alignment

        // Step 1: Create IOSurface
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: bytesPerElement,
            .bytesPerRow: alignedBytesPerRow,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]

        guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
            return nil
        }
        self.surface = surface

        let actualBytesPerRow = IOSurfaceGetBytesPerRow(surface)
        self.bytesPerRow = actualBytesPerRow

        // Step 2: Create CGContext backed by IOSurface memory
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }

        let baseAddress = IOSurfaceGetBaseAddress(surface)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: actualBytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }
        self.cgContext = context

        // Step 3: Create MTLTexture from same IOSurface (zero-copy)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0
        ) else {
            return nil
        }
        self.texture = texture
    }

    /// Render a view's current visual state into the shared surface.
    /// After this call, `self.texture` contains the rendered content with zero copy.
    func renderView(_ view: UIView, scale: CGFloat) {
        IOSurfaceLock(surface, [], nil)

        cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip coordinate system: CGContext is bottom-left, UIKit is top-left
        cgContext.saveGState()
        cgContext.translateBy(x: 0, y: CGFloat(height))
        cgContext.scaleBy(x: scale, y: -scale)

        // Use presentation layer to capture mid-animation state
        if let presentationLayer = view.layer.presentation() {
            presentationLayer.render(in: cgContext)
        } else {
            view.layer.render(in: cgContext)
        }

        cgContext.restoreGState()

        IOSurfaceUnlock(surface, [], nil)
    }
}
