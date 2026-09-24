import Foundation

/// Standalone Foundation-only checks, compiled with the demo's actual record/export files.
@main
struct ExportValidationChecks {
    static func main() throws {
        let device = BenchmarkRecord.Device(
            model: "test-device", gpuName: "test-GPU", gpuFamilies: ["apple9"],
            osVersion: "test", osBuild: "test", environment: .simulator,
            thermalState: "nominal", minimumRefreshRate: 0, maximumRefreshRate: 60
        )
        let defaultWidth = 32
        let defaultHeight = 8
        let selectedWidth = 16
        let selectedHeight = 16

        func record(_ algorithm: BenchmarkRecord.Algorithm) -> BenchmarkRecord {
            let usesDualParameters = algorithm != .mpsGaussian
            let isCompute = ![.dualKawase, .mpsGaussian].contains(algorithm)
            let profile: (down: Int, intermediate: Int, final: Int, width: Int, height: Int, selection: String)? = switch algorithm {
            case .dualKawase, .mpsGaussian: nil
            case .triangularMomentMatchedDualKawase:
                (5, 8, 3, defaultWidth, defaultHeight, "pipelineDefault")
            case .allLevelMomentMatchedDualKawase:
                (5, 4, 3, defaultWidth, defaultHeight, "pipelineDefault")
            case .tunedAllLevelMomentMatchedDualKawase:
                (5, 4, 3, selectedWidth, selectedHeight, "gpuP50Preflight")
            case .fourTapDownsampleDualKawase:
                (4, 4, 3, selectedWidth, selectedHeight, "reusedGpuP50Preflight")
            }
            let baseline: BenchmarkRecord.Algorithm? = switch algorithm {
            case .allLevelMomentMatchedDualKawase: .triangularMomentMatchedDualKawase
            case .tunedAllLevelMomentMatchedDualKawase: .allLevelMomentMatchedDualKawase
            case .fourTapDownsampleDualKawase: .tunedAllLevelMomentMatchedDualKawase
            case .dualKawase, .triangularMomentMatchedDualKawase, .mpsGaussian: nil
            }
            return .init(
                version: BenchmarkRecord.schemaVersion,
                createdAt: Date(),
                device: device,
                workload: .init(
                    width: 128, height: 64, pixelFormat: "bgra8Unorm", algorithm: algorithm,
                    iterations: usesDualParameters ? 5 : nil,
                    offset: usesDualParameters ? 2 : nil,
                    sigma: algorithm == .mpsGaussian ? 12 : nil,
                    reductionLevelCount: isCompute ? 5 : nil,
                    downsampleTapCount: profile?.down,
                    intermediateUpsampleTapCount: profile?.intermediate,
                    finalUpsampleTapCount: profile?.final,
                    threadgroupWidth: profile?.width,
                    threadgroupHeight: profile?.height,
                    threadgroupSelection: profile?.selection,
                    parameterSelection: "manual",
                    sourceSHA256: String(repeating: "a", count: 64),
                    warmUpIterations: 30,
                    measuredIterations: 1
                ),
                timings: .init(
                    cpuEncodeMilliseconds: [1], gpuMilliseconds: [2], endToEndMilliseconds: [3],
                    cpuP50: 1, cpuP95: 1, cpuP99: 1, gpuP50: 2, gpuP95: 2, gpuP99: 2
                ),
                counts: .init(
                    encoded: 1, completed: 1, droppedNoCapacity: 0,
                    droppedEncodingFailure: 0, droppedDeadline: 0
                ),
                memory: .init(
                    residentBytesBefore: nil, residentBytesAfter: nil,
                    peakResidentBytes: nil, allocationCount: nil
                ),
                quality: isCompute
                    ? .init(
                        referenceAlgorithm: .mpsGaussian,
                        normalizedLumaRMSE: 0.1,
                        dualKawaseNormalizedLumaRMSE: 0.01,
                        optimizationBaselineAlgorithm: baseline,
                        optimizationBaselineNormalizedLumaRMSE: baseline == nil ? nil : 0.005
                    )
                    : nil
            )
        }

        let tuning = BenchmarkExport.ThreadgroupTuning(
            warmUpIterations: 10,
            measuredIterations: 50,
            defaultWidth: defaultWidth,
            defaultHeight: defaultHeight,
            selectedWidth: selectedWidth,
            selectedHeight: selectedHeight,
            candidates: [
                .init(width: defaultWidth, height: defaultHeight, gpuP50: 2),
                .init(width: selectedWidth, height: selectedHeight, gpuP50: 1)
            ]
        )
        let valid = BenchmarkExport(
            schemaVersion: BenchmarkRecord.schemaVersion,
            systemMaterial: .init(style: "Ultra thin", timingIncluded: false),
            threadgroupTuning: tuning,
            records: [
                record(.dualKawase),
                record(.triangularMomentMatchedDualKawase),
                record(.allLevelMomentMatchedDualKawase),
                record(.tunedAllLevelMomentMatchedDualKawase),
                record(.fourTapDownsampleDualKawase),
                record(.mpsGaussian)
            ]
        )
        let data = try valid.validatedJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        func rejects(_ name: String, mutate: (inout [String: Any]) -> Void) throws {
            var changed = object
            mutate(&changed)
            let candidate = try decoder.decode(
                BenchmarkExport.self,
                from: JSONSerialization.data(withJSONObject: changed)
            )
            do {
                _ = try candidate.validatedJSON()
            } catch {
                print("PASS: rejects \(name)")
                return
            }
            fatalError("Accepted invalid export: \(name)")
        }

        try rejects("empty results") { $0["records"] = [] }
        try rejects("schema mismatch") { $0["schemaVersion"] = 1 }
        try rejects("invented Material timing") {
            $0["systemMaterial"] = ["style": "Ultra thin", "timingIncluded": true]
        }
        try rejects("duplicate algorithms") {
            let records = $0["records"] as! [[String: Any]]
            $0["records"] = [records[0], records[0], records[2], records[3], records[4], records[5]]
        }
        for (field, value) in [
            ("width", 256 as Any),
            ("sourceSHA256", String(repeating: "b", count: 64)),
            ("sigma", -1),
            ("measuredIterations", 2),
            ("parameterSelection", "matched")
        ] {
            try rejects(field) {
                var records = $0["records"] as! [[String: Any]]
                var workload = records[5]["workload"] as! [String: Any]
                workload[field] = value
                records[5]["workload"] = workload
                $0["records"] = records
            }
        }
        try rejects("compute candidate without quality") {
            var records = $0["records"] as! [[String: Any]]
            records[1].removeValue(forKey: "quality")
            $0["records"] = records
        }
        try rejects("four-tap downsample candidate with five taps") {
            var records = $0["records"] as! [[String: Any]]
            var workload = records[4]["workload"] as! [String: Any]
            workload["downsampleTapCount"] = 5
            records[4]["workload"] = workload
            $0["records"] = records
        }
        try rejects("tuned candidate with default threadgroup") {
            var records = $0["records"] as! [[String: Any]]
            var workload = records[3]["workload"] as! [String: Any]
            workload["threadgroupWidth"] = defaultWidth
            workload["threadgroupHeight"] = defaultHeight
            records[3]["workload"] = workload
            $0["records"] = records
        }
        try rejects("selected threadgroup is not preflight winner") {
            var tuning = $0["threadgroupTuning"] as! [String: Any]
            tuning["selectedWidth"] = defaultWidth
            tuning["selectedHeight"] = defaultHeight
            $0["threadgroupTuning"] = tuning
        }
        try rejects("duplicate preflight candidate") {
            var tuning = $0["threadgroupTuning"] as! [String: Any]
            let candidates = tuning["candidates"] as! [[String: Any]]
            tuning["candidates"] = [candidates[0], candidates[0]]
            $0["threadgroupTuning"] = tuning
        }
        try rejects("tuned candidate without direct default quality") {
            var records = $0["records"] as! [[String: Any]]
            var quality = records[3]["quality"] as! [String: Any]
            quality.removeValue(forKey: "optimizationBaselineNormalizedLumaRMSE")
            records[3]["quality"] = quality
            $0["records"] = records
        }
        try rejects("four-tap candidate with wrong direct baseline") {
            var records = $0["records"] as! [[String: Any]]
            var quality = records[4]["quality"] as! [String: Any]
            quality["optimizationBaselineAlgorithm"] = "allLevelMomentMatchedDualKawase"
            records[4]["quality"] = quality
            $0["records"] = records
        }
        print("PASS: valid schema-v9 export with absent optional memory fields")

        if let path = CommandLine.arguments.dropFirst().first {
            let exported = try decoder.decode(
                BenchmarkExport.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )
            _ = try exported.validatedJSON()
            print("PASS: device-generated export")
        }
    }
}
