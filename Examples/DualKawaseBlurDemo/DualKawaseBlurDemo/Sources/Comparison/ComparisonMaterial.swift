import SwiftUI

enum ComparisonMaterial: String, CaseIterable, Identifiable {
    case ultraThin = "Ultra thin", thin = "Thin", regular = "Regular", thick = "Thick", ultraThick = "Ultra thick"

    var id: Self { self }

    var value: Material {
        switch self {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        case .ultraThick: .ultraThickMaterial
        }
    }
}
