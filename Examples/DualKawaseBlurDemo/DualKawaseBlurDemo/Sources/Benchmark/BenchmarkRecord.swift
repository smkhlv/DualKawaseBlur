import Foundation

struct BenchmarkRecord: Codable, Sendable {
    static let schemaVersion = 1

    enum Environment: String, Codable, Sendable { case device, simulator }
    enum Algorithm: String, Codable, Sendable { case dualKawase, mpsGaussian }

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
        let matchedSecondMoment: Double
        let normalizedRMSE: Double
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
              workload.warmUpIterations >= 0,
              workload.measuredIterations > 0,
              timings.cpuEncodeMilliseconds.count == workload.measuredIterations,
              timings.gpuMilliseconds.count == workload.measuredIterations,
              timings.endToEndMilliseconds.count == workload.measuredIterations,
              timings.cpuEncodeMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              timings.gpuMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              timings.endToEndMilliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              counts.encoded >= counts.completed,
              counts.completed == timings.gpuMilliseconds.count,
              (workload.algorithm == .dualKawase && workload.iterations != nil && workload.offset != nil && workload.sigma == nil)
                || (workload.algorithm == .mpsGaussian && workload.sigma != nil && workload.iterations == nil && workload.offset == nil)
        else { throw ValidationError.invalidMeasurements }
    }
}
