import UIKit

/// A deterministic orientation/edge/detail fixture available without Photos access.
@MainActor
enum ComparisonSample {
    static func makeImage() -> UIImage {
        let size = CGSize(width: 960, height: 480)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let colors = [UIColor.systemIndigo, .systemPink, .systemOrange, .systemTeal]
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(x: index * 240, y: 0, width: 240, height: 480))
            }
            UIColor.white.setFill()
            context.fillEllipse(in: CGRect(x: 70, y: 55, width: 250, height: 250))
            UIColor.black.setFill()
            for index in 0..<14 {
                context.fill(CGRect(x: 500 + index * 24, y: 80, width: 8, height: 180))
            }
            ("Aa  •  123" as NSString).draw(at: CGPoint(x: 320, y: 300), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 68), .foregroundColor: UIColor.white
            ])
        }
    }
}
