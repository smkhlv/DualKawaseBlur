struct TexturePyramidLayout: Sendable, Equatable {
    struct Level: Sendable, Equatable {
        let width: Int
        let height: Int
    }

    let levels: [Level]

    init(width: Int, height: Int, configuration: BlurConfiguration) throws {
        try configuration.validate(forWidth: width, height: height)

        levels = (1...configuration.iterations).map { level in
            Level(width: width >> level, height: height >> level)
        }
    }
}
