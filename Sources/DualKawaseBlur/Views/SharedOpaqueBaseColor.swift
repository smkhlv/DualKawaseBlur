import UIKit

enum SharedOpaqueBaseColor {
    static func resolve(_ color: UIColor, traits: UITraitCollection) -> UIColor {
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
