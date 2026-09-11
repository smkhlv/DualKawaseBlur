import Testing
@testable import DualKawaseBlur

@Test func validLayoutHalvesWithoutZeroDimensions() throws {
    let layout = try TexturePyramidLayout(
        width: 17,
        height: 9,
        configuration: BlurConfiguration(iterations: 3, offset: 2)
    )
    #expect(layout.levels == [
        .init(width: 8, height: 4),
        .init(width: 4, height: 2),
        .init(width: 2, height: 1)
    ])
}

@Test func dualKawaseBlurErrorExposesCanonicalPayloadFreeCases() {
    let errors: [DualKawaseBlurError] = [
        .metalUnavailable,
        .libraryLoadingFailed,
        .pipelineCreationFailed,
        .invalidConfiguration,
        .unsupportedTexture,
        .textureAllocationFailed,
        .commandBufferCreationFailed,
        .gpuExecutionFailed
    ]

    #expect(errors.count == 8)
}
