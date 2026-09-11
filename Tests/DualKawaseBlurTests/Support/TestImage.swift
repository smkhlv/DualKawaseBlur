import UIKit

enum TestImage {
    @MainActor
    static func asymmetricUIImage(
        scale: CGFloat,
        orientation: UIImage.Orientation
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let base = UIGraphicsImageRenderer(
            size: CGSize(width: 8, height: 4),
            format: format
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
            UIColor.green.setFill()
            context.fill(CGRect(x: 4, y: 0, width: 4, height: 2))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 4, y: 2, width: 4, height: 2))
        }
        return UIImage(
            cgImage: base.cgImage!,
            scale: scale,
            orientation: orientation
        )
    }

    @MainActor
    static func largeUIImage() -> UIImage {
        let size = CGSize(width: 2048, height: 2048)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor.red.cgColor, UIColor.blue.cgColor] as CFArray
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors,
                locations: [0, 1]
            )!
            context.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
    }

    @MainActor
    static func partiallyTransparentUIImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            UIColor.red.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        }
    }

    @MainActor
    static func displayP3UIImage() -> UIImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let context = CGContext(
            data: &bytes, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return UIImage(cgImage: context.makeImage()!, scale: 1, orientation: .up)
    }
}
