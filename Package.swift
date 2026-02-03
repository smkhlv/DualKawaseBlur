// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DualKawaseBlur",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "DualKawaseBlur",
            targets: ["DualKawaseBlur"]
        )
    ],
    targets: [
        .target(
            name: "DualKawaseBlur",
            path: "Sources/DualKawaseBlur",
            resources: [
                .process("Resources/DualKawaseShaders.metal")
            ]
        )
    ]
)
