/// Geometry for an experimental filtered-reduction blur path.
///
/// The plan intentionally stops before a level would have a zero dimension.
struct ReducedResolutionPlan: Equatable, Sendable {
    struct Level: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    let levels: [Level]

    init(width: Int, height: Int, levels requestedLevels: Int) throws {
        guard width > 0, height > 0, requestedLevels > 0 else {
            throw DualKawaseBlurError.invalidConfiguration
        }

        var reducedLevels: [Level] = []
        reducedLevels.reserveCapacity(requestedLevels)
        var currentWidth = width
        var currentHeight = height

        for _ in 0..<requestedLevels {
            let nextWidth = currentWidth / 2
            let nextHeight = currentHeight / 2
            guard nextWidth > 0, nextHeight > 0 else { break }
            reducedLevels.append(.init(width: nextWidth, height: nextHeight))
            currentWidth = nextWidth
            currentHeight = nextHeight
        }

        guard reducedLevels.isEmpty == false else {
            throw DualKawaseBlurError.invalidConfiguration
        }
        levels = reducedLevels
    }
}
