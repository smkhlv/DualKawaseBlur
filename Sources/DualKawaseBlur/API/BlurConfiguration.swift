public struct BlurConfiguration: Sendable, Hashable {
    public enum ValidationError: Error, Sendable, Equatable {
        case invalidIterations
        case invalidOffset
        case invalidDimensions
        case insufficientDimensions
    }

    public var iterations: Int
    public var offset: Float

    public init(iterations: Int = 3, offset: Float = 1) {
        self.iterations = iterations
        self.offset = offset
    }

    public func validate(forWidth width: Int, height: Int) throws {
        guard iterations > 0 else {
            throw ValidationError.invalidIterations
        }
        guard offset.isFinite, offset > 0 else {
            throw ValidationError.invalidOffset
        }
        guard width > 0, height > 0 else {
            throw ValidationError.invalidDimensions
        }
        guard iterations < Int.bitWidth, min(width, height) >> iterations >= 1 else {
            throw ValidationError.insufficientDimensions
        }
    }
}
