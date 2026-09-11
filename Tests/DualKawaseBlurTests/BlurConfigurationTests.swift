import Testing
@testable import DualKawaseBlur

@Test func validationRejectsInvalidIterationsWithExactError() {
    expectValidationError(.invalidIterations) {
        try BlurConfiguration(iterations: 0, offset: 2).validate(forWidth: 32, height: 32)
    }
}

@Test func validationRejectsNonFiniteAndNonPositiveOffsetsWithExactError() {
    for offset: Float in [.nan, .infinity, -.infinity, 0, -1] {
        expectValidationError(.invalidOffset) {
            try BlurConfiguration(iterations: 1, offset: offset).validate(forWidth: 32, height: 32)
        }
    }
}

@Test func validationRejectsNonPositiveDimensionsWithExactError() {
    for dimensions in [(0, 32), (-1, 32), (32, 0), (32, -1)] {
        expectValidationError(.invalidDimensions) {
            try BlurConfiguration(iterations: 1, offset: 2).validate(forWidth: dimensions.0, height: dimensions.1)
        }
    }
}

@Test func validationAcceptsExactFinalDimensionBoundary() throws {
    try BlurConfiguration(iterations: 3, offset: 2).validate(forWidth: 8, height: 8)
}

@Test func validationRejectsZeroFinalDimensionAndOversizedShiftWithExactError() {
    expectValidationError(.insufficientDimensions) {
        try BlurConfiguration(iterations: 3, offset: 2).validate(forWidth: 7, height: 7)
    }
    expectValidationError(.insufficientDimensions) {
        try BlurConfiguration(iterations: Int.bitWidth, offset: 2).validate(forWidth: .max, height: .max)
    }
}

private func expectValidationError(
    _ expectedError: BlurConfiguration.ValidationError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected \(expectedError) to be thrown")
    } catch let error as BlurConfiguration.ValidationError {
        #expect(error == expectedError)
    } catch {
        Issue.record("Expected BlurConfiguration.ValidationError, got \(error)")
    }
}
