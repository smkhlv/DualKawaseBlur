import Foundation

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

    /// A deterministic comparison signal for BGRA8 readback. Alpha is excluded
    /// because every benchmark source is normalized to opaque RGB before upload.
    public static func normalizedLumaRMSE(referenceBGRA: Data, candidateBGRA: Data) -> Double {
        guard referenceBGRA.isEmpty == false,
              referenceBGRA.count == candidateBGRA.count,
              referenceBGRA.count.isMultiple(of: 4) else {
            return .infinity
        }

        let reference = [UInt8](referenceBGRA)
        let candidate = [UInt8](candidateBGRA)
        var squaredError = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity

        for index in stride(from: 0, to: reference.count, by: 4) {
            let referenceLuma = 0.0722 * Double(reference[index])
                + 0.7152 * Double(reference[index + 1])
                + 0.2126 * Double(reference[index + 2])
            let candidateLuma = 0.0722 * Double(candidate[index])
                + 0.7152 * Double(candidate[index + 1])
                + 0.2126 * Double(candidate[index + 2])
            let difference = referenceLuma - candidateLuma
            squaredError += difference * difference
            minimum = min(minimum, referenceLuma)
            maximum = max(maximum, referenceLuma)
        }

        let sampleCount = Double(reference.count / 4)
        let rmse = (squaredError / sampleCount).squareRoot()
        let referenceRange = maximum - minimum
        return referenceRange > 0 ? rmse / referenceRange : rmse
    }
}
