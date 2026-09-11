// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DualKawaseBlur",
    platforms: [.iOS(.v18)],
    products: [.library(name: "DualKawaseBlur", targets: ["DualKawaseBlur"])],
    targets: [
        .target(
            name: "DualKawaseBlur",
            path: "Sources/DualKawaseBlur",
            resources: [.process("Resources/DualKawaseShaders.metal")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "DualKawaseBlurTests", dependencies: ["DualKawaseBlur"])
    ]
)
