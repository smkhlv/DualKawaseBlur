import Foundation

struct BenchmarkRecord: Codable, Sendable {
    static let schemaVersion = 9

    enum Environment: String, Codable, Sendable { case device, simulator }
    enum Algorithm: String, Codable, Sendable, Hashable {
        case dualKawase
        case triangularMomentMatchedDualKawase
        case allLevelMomentMatchedDualKawase
        case tunedAllLevelMomentMatchedDualKawase
        case fourTapDownsampleDualKawase
        case mpsGaussian
    }

    struct Device: Codable, Sendable {
        let model: String
        let gpuName: String
        let gpuFamilies: [String]
        let osVersion: String
        let osBuild: String
        let environment: Environment
        let thermalState: String
        let minimumRefreshRate: Double
        let maximumRefreshRate: Double
    }

    struct Workload: Codable, Sendable {
        let width: Int
        let height: Int
        let pixelFormat: String
        let algorithm: Algorithm
        let iterations: Int?
        let offset: Float?
        let sigma: Float?
        let reductionLevelCount: Int?
        let downsampleTapCount: Int?
        let intermediateUpsampleTapCount: Int?
        let finalUpsampleTapCount: Int?
        let threadgroupWidth: Int?
        let threadgroupHeight: Int?
        let threadgroupSelection: String?
        let parameterSelection: String
        let sourceSHA256: String
        let warmUpIterations: Int
        let measuredIterations: Int
    }

    struct Timings: Codable, Sendable {
        let cpuEncodeMilliseconds: [Double]
        let gpuMilliseconds: [Double]
        let endToEndMilliseconds: [Double]
        let cpuP50: Double
        let cpuP95: Double
        let cpuP99: Double
        let gpuP50: Double
        let gpuP95: Double
        let gpuP99: Double
    }

    struct Counts: Codable, Sendable {
        let encoded: Int
        let completed: Int
        let droppedNoCapacity: Int
        let droppedEncodingFailure: Int
        let droppedDeadline: Int
    }

    struct Memory: Codable, Sendable {
        let residentBytesBefore: UInt64?
        let residentBytesAfter: UInt64?
        let peakResidentBytes: UInt64?
        let allocationCount: UInt64?
    }

    struct Quality: Codable, Sendable {
        let referenceAlgorithm: Algorithm
        let normalizedLumaRMSE: Double
        let dualKawaseNormalizedLumaRMSE: Double?
        let optimizationBaselineAlgorithm: Algorithm?
        let optimizationBaselineNormalizedLumaRMSE: Double?
    }

    enum ValidationError: LocalizedError {
        case missingMetadata(String)
        case invalidMeasurements

        var errorDescription: String? {
            switch self {
            case let .missingMetadata(field): "Missing required benchmark metadata: \(field)"
            case .invalidMeasurements: "Benchmark samples and counts are inconsistent."
            }
        }
    }

    let version: Int
    let createdAt: Date
    let device: Device
    let workload: Workload
    let timings: Timings
    let counts: Counts
    let memory: Memory
    let quality: Quality?

    func validatedJSON() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func validate() throws {
        let required: [(String, String)] = [
            ("device.model", device.model),
            ("device.gpuName", device.gpuName),
            ("device.osVersion", device.osVersion),
            ("device.osBuild", device.osBuild),
            ("workload.pixelFormat", workload.pixelFormat)
        ]
        if let missing = required.first(where: { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ValidationError.missingMetadata(missing.0)
        }
        guard version == Self.schemaVersion,
              device.gpuFamilies.isEmpty == false,
              device.maximumRefreshRate > 0,
              workload.width > 0,
              workload.height > 0,
              workload.parameterSelection == "manual",
              workload.sourceSHA256.count == 64,
              workload.sourceSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
              workload.pixelFormat == "bgra8Unorm",
              workload.warmUpIterations >= 0,
              workload.measuredIterations > 0,
              timings.cpuEncodeMilliseconds.count == workload.measuredIterations,
              timings.gpuMilliseconds.count == workload.measuredIterations,
              timings.endToEndMilliseconds.count == workload.measuredIterations,
              timings.cpuEncodeMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              timings.gpuMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              timings.endToEndMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              counts.encoded == counts.completed,
              counts.droppedNoCapacity == 0,
              counts.droppedEncodingFailure == 0,
              counts.droppedDeadline == 0,
              counts.completed == timings.gpuMilliseconds.count,
              isValidAlgorithmConfiguration
        else { throw ValidationError.invalidMeasurements }
    }

    private var isValidAlgorithmConfiguration: Bool {
        let hasValidIterations = (workload.iterations ?? 0) > 0
        let hasValidOffset = (workload.offset ?? 0) > 0 && workload.offset?.isFinite == true
        let hasValidSigma = (workload.sigma ?? 0) > 0 && workload.sigma?.isFinite == true
        let hasValidReduction = (workload.reductionLevelCount ?? 0) > 0
        let hasQuality = quality?.referenceAlgorithm == .mpsGaussian
            && quality?.normalizedLumaRMSE.isFinite == true
            && quality?.normalizedLumaRMSE ?? -.infinity >= 0
        let hasDualReferenceQuality = quality?.dualKawaseNormalizedLumaRMSE?.isFinite == true
            && quality?.dualKawaseNormalizedLumaRMSE ?? -.infinity >= 0
        let hasThreeTapBaselineQuality = quality?.optimizationBaselineAlgorithm == .triangularMomentMatchedDualKawase
            && quality?.optimizationBaselineNormalizedLumaRMSE?.isFinite == true
            && quality?.optimizationBaselineNormalizedLumaRMSE ?? -.infinity >= 0
        let hasAllLevelBaselineQuality = quality?.optimizationBaselineAlgorithm == .allLevelMomentMatchedDualKawase
            && quality?.optimizationBaselineNormalizedLumaRMSE?.isFinite == true
            && quality?.optimizationBaselineNormalizedLumaRMSE ?? -.infinity >= 0
        let hasTunedAllLevelBaselineQuality = quality?.optimizationBaselineAlgorithm == .tunedAllLevelMomentMatchedDualKawase
            && quality?.optimizationBaselineNormalizedLumaRMSE?.isFinite == true
            && quality?.optimizationBaselineNormalizedLumaRMSE ?? -.infinity >= 0
        let hasValidThreadgroup = (workload.threadgroupWidth ?? 0) > 0
            && (workload.threadgroupHeight ?? 0) > 0

        switch workload.algorithm {
        case .dualKawase:
            return hasValidIterations && hasValidOffset && workload.sigma == nil
                && workload.reductionLevelCount == nil && workload.downsampleTapCount == nil
                && workload.intermediateUpsampleTapCount == nil
                && workload.finalUpsampleTapCount == nil && workload.threadgroupWidth == nil
                && workload.threadgroupHeight == nil && workload.threadgroupSelection == nil
                && quality == nil
        case .triangularMomentMatchedDualKawase:
            return hasValidIterations && hasValidOffset && workload.sigma == nil && hasValidReduction
                && workload.reductionLevelCount == workload.iterations
                && workload.downsampleTapCount == 5
                && workload.intermediateUpsampleTapCount == 8
                && workload.finalUpsampleTapCount == 3
                && hasValidThreadgroup && workload.threadgroupSelection == "pipelineDefault"
                && hasQuality && hasDualReferenceQuality
        case .allLevelMomentMatchedDualKawase:
            return hasValidIterations && hasValidOffset && workload.sigma == nil && hasValidReduction
                && workload.reductionLevelCount == workload.iterations
                && workload.downsampleTapCount == 5
                && workload.intermediateUpsampleTapCount == 4
                && workload.finalUpsampleTapCount == 3
                && hasValidThreadgroup && workload.threadgroupSelection == "pipelineDefault"
                && hasQuality && hasDualReferenceQuality && hasThreeTapBaselineQuality
        case .tunedAllLevelMomentMatchedDualKawase:
            return hasValidIterations && hasValidOffset && workload.sigma == nil && hasValidReduction
                && workload.reductionLevelCount == workload.iterations
                && workload.downsampleTapCount == 5
                && workload.intermediateUpsampleTapCount == 4
                && workload.finalUpsampleTapCount == 3
                && hasValidThreadgroup && workload.threadgroupSelection == "gpuP50Preflight"
                && hasQuality && hasDualReferenceQuality && hasAllLevelBaselineQuality
        case .fourTapDownsampleDualKawase:
            return hasValidIterations && hasValidOffset && workload.sigma == nil && hasValidReduction
                && workload.reductionLevelCount == workload.iterations
                && workload.downsampleTapCount == 4
                && workload.intermediateUpsampleTapCount == 4
                && workload.finalUpsampleTapCount == 3
                && hasValidThreadgroup && workload.threadgroupSelection == "reusedGpuP50Preflight"
                && hasQuality && hasDualReferenceQuality && hasTunedAllLevelBaselineQuality
        case .mpsGaussian:
            return hasValidSigma && workload.iterations == nil && workload.offset == nil
                && workload.reductionLevelCount == nil && workload.downsampleTapCount == nil
                && workload.intermediateUpsampleTapCount == nil
                && workload.finalUpsampleTapCount == nil && workload.threadgroupWidth == nil
                && workload.threadgroupHeight == nil && workload.threadgroupSelection == nil
                && quality == nil
        }
    }
}
