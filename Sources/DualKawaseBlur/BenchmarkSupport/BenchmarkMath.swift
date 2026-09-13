@_spi(Benchmark)
public enum BenchmarkMath {
    public static func percentile(_ values: [Double], _ probability: Double) -> Double {
        guard values.isEmpty == false else { return 0 }

        let sortedValues = values.sorted()
        let boundedProbability = min(max(probability, 0), 1)
        let rank = max(1, Int((boundedProbability * Double(sortedValues.count)).rounded(.up)))
        return sortedValues[rank - 1]
    }

    public static func secondMoment(_ weights: [Double]) -> Double {
        guard weights.isEmpty == false else { return 0 }

        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0, totalWeight.isFinite else { return 0 }

        let center = Double(weights.count - 1) / 2
        let weightedSquaredDistance = weights.enumerated().reduce(0.0) { result, element in
            let distance = Double(element.offset) - center
            return result + element.element * distance * distance
        }
        return weightedSquaredDistance / totalWeight
    }

    public static func normalizedRMSE(_ reference: [Double], _ candidate: [Double]) -> Double {
        guard reference.isEmpty == false, reference.count == candidate.count else {
            return .infinity
        }

        let squaredError = zip(reference, candidate).reduce(0.0) { result, pair in
            let difference = pair.0 - pair.1
            return result + difference * difference
        }
        let rmse = (squaredError / Double(reference.count)).squareRoot()
        let referenceRange = (reference.max() ?? 0) - (reference.min() ?? 0)
        return referenceRange > 0 ? rmse / referenceRange : rmse
    }
}
