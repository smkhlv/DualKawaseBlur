import Testing
@testable import DualKawaseBlur

@Test func twoReductionsReachQuarterResolution() throws {
    let plan = try ReducedResolutionPlan(width: 1_084, height: 446, levels: 2)

    #expect(plan.levels == [
        .init(width: 542, height: 223),
        .init(width: 271, height: 111)
    ])
}

@Test func reductionsStopBeforeAnyDimensionBecomesZero() throws {
    let plan = try ReducedResolutionPlan(width: 3, height: 2, levels: 2)

    #expect(plan.levels == [.init(width: 1, height: 1)])
}
