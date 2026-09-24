import Darwin
import CryptoKit
import Foundation
import Metal
import Observation
import UIKit
@_spi(Benchmark) import DualKawaseBlur

@MainActor @Observable
final class BenchmarkViewModel {
    var progress = 0.0
    var status = "Ready"
    var isRunning = false
    var exportURL: URL?
    var errorMessage = ""
    var isShowingError = false

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    private(set) var summary = ""

    func start(input: ComparisonBenchmarkInput) {
        guard !isRunning else { return }
        generation &+= 1
        let generation = generation
        exportURL = nil
        summary = ""
        errorMessage = ""
        isShowingError = false
        isRunning = true
        progress = 0
        runTask = Task { await performRun(input: input, generation: generation) }
    }

    func cancel() {
        guard isRunning else { return }
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = "Cancelled"
    }

    private func performRun(input: ComparisonBenchmarkInput, generation: UInt64) async {
        defer {
            if generation == self.generation { isRunning = false; runTask = nil }
        }
        do {
            let request = input.request
            let configuration = BlurConfiguration(iterations: request.iterations, offset: request.offset)
            let sourceHash = SHA256.hash(data: input.pixels)
                .map { String(format: "%02x", $0) }
                .joined()
            try Task.checkCancellation()
            status = "Tuning threadgroups, then running 30 warm-up + 300 measured runs…"
            let memoryBefore = Self.residentBytes()
            let output = try await BlurBenchmarkRunner().run(
                configuration: configuration,
                sigma: request.sigma,
                width: request.width,
                height: request.height,
                sourcePixels: input.pixels
            ) { [weak self] value in
                guard let self, self.generation == generation else { return }
                if value - self.progress >= 0.025 || value == 1 { self.progress = value }
            }
            try Task.checkCancellation()
            guard generation == self.generation else { return }
            let memoryAfter = Self.residentBytes()
            let metadata = try Self.deviceMetadata()
            let records = [
                makeRecord(.dualKawase, samples: output.dualKawase, output: output,
                           request: request, sourceHash: sourceHash, metadata: metadata,
                           memoryBefore: memoryBefore, memoryAfter: memoryAfter),
                makeRecord(.triangularMomentMatchedDualKawase,
                           samples: output.triangularMomentMatchedDualKawase, output: output,
                           request: request, sourceHash: sourceHash, metadata: metadata,
                           memoryBefore: memoryBefore, memoryAfter: memoryAfter),
                makeRecord(.allLevelMomentMatchedDualKawase,
                           samples: output.allLevelDefaultThreadgroup, output: output,
                           request: request, sourceHash: sourceHash, metadata: metadata,
                           memoryBefore: memoryBefore, memoryAfter: memoryAfter),
                makeRecord(.tunedAllLevelMomentMatchedDualKawase,
                           samples: output.allLevelTunedThreadgroup, output: output,
                           request: request, sourceHash: sourceHash, metadata: metadata,
                           memoryBefore: memoryBefore, memoryAfter: memoryAfter),
                makeRecord(.fourTapDownsampleDualKawase,
                           samples: output.fourTapDownsampleDualKawase, output: output,
                           request: request, sourceHash: sourceHash, metadata: metadata,
                           memoryBefore: memoryBefore, memoryAfter: memoryAfter),
                makeRecord(.mpsGaussian, samples: output.mpsGaussian, output: output,
                           request: request, sourceHash: sourceHash, metadata: metadata,
                           memoryBefore: memoryBefore, memoryAfter: memoryAfter)
            ]
            let tuning = BenchmarkExport.ThreadgroupTuning(
                warmUpIterations: output.threadgroupTuning.warmUpIterations,
                measuredIterations: output.threadgroupTuning.measuredIterations,
                defaultWidth: output.threadgroupTuning.defaultSize.width,
                defaultHeight: output.threadgroupTuning.defaultSize.height,
                selectedWidth: output.threadgroupTuning.selectedSize.width,
                selectedHeight: output.threadgroupTuning.selectedSize.height,
                candidates: output.threadgroupTuning.candidates.map {
                    .init(width: $0.width, height: $0.height, gpuP50: $0.gpuP50)
                }
            )
            let data = try BenchmarkExport(
                schemaVersion: BenchmarkRecord.schemaVersion,
                systemMaterial: .init(style: input.materialStyle, timingIncluded: false),
                threadgroupTuning: tuning,
                records: records
            ).validatedJSON()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dual-kawase-benchmark-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
            summary = "GPU p50: Render \(format(records[0])) · 3-tap \(format(records[1])) · All-level \(format(records[2])) · Tuned \(format(records[3])) · 4-down \(format(records[4])) · MPS \(format(records[5])) ms · TG \(tuning.selectedWidth)×\(tuning.selectedHeight)"
            status = metadata.environment == .simulator
                ? "Simulator smoke result — not publishable"
                : "Completed"
        } catch is CancellationError {
            if generation == self.generation { status = "Cancelled" }
        } catch {
            guard generation == self.generation else { return }
            errorMessage = error.localizedDescription
            isShowingError = true
            status = "Failed"
        }
    }

    private func format(_ record: BenchmarkRecord) -> String {
        record.timings.gpuP50.formatted(.number.precision(.fractionLength(2)))
    }

    private func makeRecord(
        _ algorithm: BenchmarkRecord.Algorithm,
        samples: BlurBenchmarkRunner.Samples,
        output: BlurBenchmarkRunner.Output,
        request: ComparisonRequest,
        sourceHash: String,
        metadata: BenchmarkRecord.Device,
        memoryBefore: UInt64?,
        memoryAfter: UInt64?
    ) -> BenchmarkRecord {
        let profile = computeProfile(for: algorithm, output: output)
        let usesDualParameters = algorithm != .mpsGaussian
        return BenchmarkRecord(
            version: BenchmarkRecord.schemaVersion,
            createdAt: Date(),
            device: metadata,
            workload: .init(
                width: request.width,
                height: request.height,
                pixelFormat: "bgra8Unorm",
                algorithm: algorithm,
                iterations: usesDualParameters ? request.iterations : nil,
                offset: usesDualParameters ? request.offset : nil,
                sigma: algorithm == .mpsGaussian ? request.sigma : nil,
                reductionLevelCount: profile?.reductionLevelCount,
                downsampleTapCount: profile?.downsampleTapCount,
                intermediateUpsampleTapCount: profile?.intermediateUpsampleTapCount,
                finalUpsampleTapCount: profile?.finalUpsampleTapCount,
                threadgroupWidth: profile?.threadgroupSize.width,
                threadgroupHeight: profile?.threadgroupSize.height,
                threadgroupSelection: threadgroupSelection(for: algorithm),
                parameterSelection: "manual",
                sourceSHA256: sourceHash,
                warmUpIterations: output.warmUpIterations,
                measuredIterations: output.measuredIterations
            ),
            timings: .init(
                cpuEncodeMilliseconds: samples.cpuEncodeMilliseconds,
                gpuMilliseconds: samples.gpuMilliseconds,
                endToEndMilliseconds: samples.endToEndMilliseconds,
                cpuP50: BenchmarkMath.percentile(samples.cpuEncodeMilliseconds, 0.50),
                cpuP95: BenchmarkMath.percentile(samples.cpuEncodeMilliseconds, 0.95),
                cpuP99: BenchmarkMath.percentile(samples.cpuEncodeMilliseconds, 0.99),
                gpuP50: BenchmarkMath.percentile(samples.gpuMilliseconds, 0.50),
                gpuP95: BenchmarkMath.percentile(samples.gpuMilliseconds, 0.95),
                gpuP99: BenchmarkMath.percentile(samples.gpuMilliseconds, 0.99)
            ),
            counts: .init(
                encoded: output.measuredIterations,
                completed: samples.gpuMilliseconds.count,
                droppedNoCapacity: 0,
                droppedEncodingFailure: 0,
                droppedDeadline: 0
            ),
            memory: .init(
                residentBytesBefore: memoryBefore,
                residentBytesAfter: memoryAfter,
                peakResidentBytes: nil,
                allocationCount: nil
            ),
            quality: quality(for: algorithm, output: output)
        )
    }

    private func computeProfile(
        for algorithm: BenchmarkRecord.Algorithm,
        output: BlurBenchmarkRunner.Output
    ) -> BlurBenchmarkRunner.ComputeProfile? {
        switch algorithm {
        case .triangularMomentMatchedDualKawase: output.triangularEncoder
        case .allLevelMomentMatchedDualKawase: output.allLevelDefaultEncoder
        case .tunedAllLevelMomentMatchedDualKawase: output.allLevelTunedEncoder
        case .fourTapDownsampleDualKawase: output.fourTapDownsampleEncoder
        case .dualKawase, .mpsGaussian: nil
        }
    }

    private func threadgroupSelection(for algorithm: BenchmarkRecord.Algorithm) -> String? {
        switch algorithm {
        case .triangularMomentMatchedDualKawase, .allLevelMomentMatchedDualKawase:
            "pipelineDefault"
        case .tunedAllLevelMomentMatchedDualKawase:
            "gpuP50Preflight"
        case .fourTapDownsampleDualKawase:
            "reusedGpuP50Preflight"
        case .dualKawase, .mpsGaussian:
            nil
        }
    }

    private func quality(
        for algorithm: BenchmarkRecord.Algorithm,
        output: BlurBenchmarkRunner.Output
    ) -> BenchmarkRecord.Quality? {
        switch algorithm {
        case .triangularMomentMatchedDualKawase:
            .init(
                referenceAlgorithm: .mpsGaussian,
                normalizedLumaRMSE: output.quality.triangularMPS,
                dualKawaseNormalizedLumaRMSE: output.quality.triangularRenderDual,
                optimizationBaselineAlgorithm: nil,
                optimizationBaselineNormalizedLumaRMSE: nil
            )
        case .allLevelMomentMatchedDualKawase:
            .init(
                referenceAlgorithm: .mpsGaussian,
                normalizedLumaRMSE: output.quality.allLevelDefaultMPS,
                dualKawaseNormalizedLumaRMSE: output.quality.allLevelDefaultRenderDual,
                optimizationBaselineAlgorithm: .triangularMomentMatchedDualKawase,
                optimizationBaselineNormalizedLumaRMSE: output.quality.allLevelDefaultThreeTap
            )
        case .tunedAllLevelMomentMatchedDualKawase:
            .init(
                referenceAlgorithm: .mpsGaussian,
                normalizedLumaRMSE: output.quality.allLevelTunedMPS,
                dualKawaseNormalizedLumaRMSE: output.quality.allLevelTunedRenderDual,
                optimizationBaselineAlgorithm: .allLevelMomentMatchedDualKawase,
                optimizationBaselineNormalizedLumaRMSE: output.quality.allLevelTunedDefault
            )
        case .fourTapDownsampleDualKawase:
            .init(
                referenceAlgorithm: .mpsGaussian,
                normalizedLumaRMSE: output.quality.fourTapDownsampleMPS,
                dualKawaseNormalizedLumaRMSE: output.quality.fourTapDownsampleRenderDual,
                optimizationBaselineAlgorithm: .tunedAllLevelMomentMatchedDualKawase,
                optimizationBaselineNormalizedLumaRMSE: output.quality.fourTapDownsampleAllLevel
            )
        case .dualKawase, .mpsGaussian:
            nil
        }
    }

    private static func deviceMetadata() throws -> BenchmarkRecord.Device {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BlurBenchmarkRunner.RunnerError.metalUnavailable
        }
        let process = ProcessInfo.processInfo
        #if targetEnvironment(simulator)
        let environment: BenchmarkRecord.Environment = .simulator
        #else
        let environment: BenchmarkRecord.Environment = .device
        #endif
        return .init(
            model: sysctlString("hw.machine"),
            gpuName: device.name,
            gpuFamilies: supportedFamilies(device),
            osVersion: process.operatingSystemVersionString,
            osBuild: sysctlString("kern.osversion"),
            environment: environment,
            thermalState: thermalStateName(process.thermalState),
            minimumRefreshRate: 0,
            maximumRefreshRate: Double(UIScreen.main.maximumFramesPerSecond)
        )
    }

    private static func supportedFamilies(_ device: MTLDevice) -> [String] {
        [(MTLGPUFamily.apple1, "apple1"), (.apple2, "apple2"), (.apple3, "apple3"),
         (.apple4, "apple4"), (.apple5, "apple5"), (.apple6, "apple6"),
         (.apple7, "apple7"), (.apple8, "apple8"), (.apple9, "apple9")]
            .compactMap { device.supportsFamily($0.0) ? $0.1 : nil }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "unknown" }
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}
