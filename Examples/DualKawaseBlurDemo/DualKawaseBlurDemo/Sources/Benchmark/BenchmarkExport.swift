import Foundation

struct BenchmarkExport: Codable, Sendable {
    struct SystemMaterial: Codable, Sendable {
        let style: String
        let timingIncluded: Bool
    }

    struct ThreadgroupTuning: Codable, Sendable {
        struct Candidate: Codable, Sendable {
            let width: Int
            let height: Int
            let gpuP50: Double
        }

        let warmUpIterations: Int
        let measuredIterations: Int
        let defaultWidth: Int
        let defaultHeight: Int
        let selectedWidth: Int
        let selectedHeight: Int
        let candidates: [Candidate]
    }

    let schemaVersion: Int
    let systemMaterial: SystemMaterial
    let threadgroupTuning: ThreadgroupTuning
    let records: [BenchmarkRecord]

    func validatedJSON() throws -> Data {
        guard schemaVersion == BenchmarkRecord.schemaVersion, records.count == 6,
              records[0].workload.algorithm == .dualKawase,
              records[1].workload.algorithm == .triangularMomentMatchedDualKawase,
              records[2].workload.algorithm == .allLevelMomentMatchedDualKawase,
              records[3].workload.algorithm == .tunedAllLevelMomentMatchedDualKawase,
              records[4].workload.algorithm == .fourTapDownsampleDualKawase,
              records[5].workload.algorithm == .mpsGaussian,
              Set(records.map(\.workload.width)).count == 1,
              Set(records.map(\.workload.height)).count == 1,
              Set(records.map(\.workload.sourceSHA256)).count == 1,
              Set(records.map(\.workload.warmUpIterations)).count == 1,
              Set(records.map(\.workload.measuredIterations)).count == 1,
              isValidThreadgroupTuning,
              !systemMaterial.style.isEmpty, !systemMaterial.timingIncluded else {
            throw BenchmarkRecord.ValidationError.invalidMeasurements
        }
        try records.forEach { try $0.validate() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private var isValidThreadgroupTuning: Bool {
        guard threadgroupTuning.warmUpIterations > 0,
              threadgroupTuning.measuredIterations > 0,
              threadgroupTuning.defaultWidth > 0,
              threadgroupTuning.defaultHeight > 0,
              threadgroupTuning.selectedWidth > 0,
              threadgroupTuning.selectedHeight > 0,
              threadgroupTuning.candidates.isEmpty == false,
              threadgroupTuning.candidates.allSatisfy({
                  $0.width > 0 && $0.height > 0 && $0.gpuP50.isFinite && $0.gpuP50 >= 0
              }),
              Set(threadgroupTuning.candidates.map { "\($0.width)x\($0.height)" }).count
                == threadgroupTuning.candidates.count,
              let selected = threadgroupTuning.candidates.first(where: {
                  $0.width == threadgroupTuning.selectedWidth
                      && $0.height == threadgroupTuning.selectedHeight
              }),
              selected.gpuP50 == threadgroupTuning.candidates.map(\.gpuP50).min(),
              let defaultRecord = records[safe: 2],
              let tunedRecord = records[safe: 3],
              let fourDownRecord = records[safe: 4] else { return false }
        return defaultRecord.workload.threadgroupWidth == threadgroupTuning.defaultWidth
            && defaultRecord.workload.threadgroupHeight == threadgroupTuning.defaultHeight
            && tunedRecord.workload.threadgroupWidth == threadgroupTuning.selectedWidth
            && tunedRecord.workload.threadgroupHeight == threadgroupTuning.selectedHeight
            && fourDownRecord.workload.threadgroupWidth == threadgroupTuning.selectedWidth
            && fourDownRecord.workload.threadgroupHeight == threadgroupTuning.selectedHeight
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
