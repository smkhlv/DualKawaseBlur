import SwiftUI
import UIKit

/// Opaque base backing with an optional shared Metal blur layer.
@MainActor
public struct SharedMetalBackgroundView: UIViewControllerRepresentable {
    private let session: SharedMetalBlurSession?
    private let baseColor: UIColor

    public init(session: SharedMetalBlurSession?, baseColor: UIColor) {
        self.session = session
        self.baseColor = baseColor
    }

    public func makeUIViewController(context: Context) -> SharedMetalBackgroundController {
        SharedMetalBackgroundController(session: session, baseColor: baseColor)
    }

    public func updateUIViewController(_ controller: SharedMetalBackgroundController, context: Context) {
        controller.update(session: session, baseColor: baseColor)
    }

    public static func dismantleUIViewController(_ controller: SharedMetalBackgroundController, coordinator: ()) {
        controller.stopPresenting()
    }
}
