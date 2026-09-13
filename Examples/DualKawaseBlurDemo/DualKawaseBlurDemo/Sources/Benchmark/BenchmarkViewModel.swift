import Darwin
import Foundation
import Metal
import Observation
import UIKit
@_spi(Benchmark) import DualKawaseBlur

@MainActor @Observable
final class BenchmarkViewModel {
    var iterations = 3
    var offset: Float = 2
    var resolutionIndex = 0
    var progress = 0.0
    var status = "Ready"
    var isRunning = false
    var exportURL: URL?
    var errorMessage = ""
    var isShowingError = false

    @ObservationIgnored private var runTask: Task<Void, Never>?

    let resolutions = [(name: "720p", width: 1280, height: 720),
                       (name: "1080p", width: 1920, height: 1080),
                       (name: "1440p", width: 2560, height: 1440)]

    func start() {
        runTask?.cancel()
        exportURL = nil
        errorMessage = ""
        isShowingError = false
        isRunning = true
        progress = 0
        runTask = Task { await performRun() }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = "Cancelled"
    }

    private func performRun() async {
        defer { isRunning = false; runTask = nil }
        do {
            let configuration = BlurConfiguration(iterations: iterations, offset: offset)
            let resolution = resolutions[resolutionIndex]
            status = "Matching blur strength…"
            let match = try await BlurStrengthMatcher().match(configuration: configuration)
            try Task.checkCancellation()
            status = "Running 30 warm-up + 300 measured pairs…"
            let memoryBefore = Self.residentBytes()
            let output = try await BlurBenchmarkRunner().run(
                configuration: configuration,
                matchedSigma: match.sigma,
                width: resolution.width,
                height: resolution.height
            ) { [weak self] value in self?.progress = value }
            let memoryAfter = Self.residentBytes()
            let metadata = try Self.deviceMetadata()
            let records = [
                makeRecord(.dualKawase, samples: output.dualKawase, output: output, match: match,
                           metadata: metadata, width: resolution.width, height: resolution.height,
                           memoryBefore: memoryBefore, memoryAfter: memoryAfter),
                makeRecord(.mpsGaussian, samples: output.mpsGaussian, output: output, match: match,
                           metadata: metadata, width: resolution.width, height: resolution.height,
                           memoryBefore: memoryBefore, memoryAfter: memoryAfter)
            ]
            let data = try BenchmarkExport(schemaVersion: 1, records: records).validatedJSON()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dual-kawase-benchmark-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url, options: .atomic)
            exportURL = url
            status = metadata.environment == .simulator
                ? "Simulator smoke result — not publishable"
                : "Completed"
        } catch is CancellationError {
            status = "Cancelled"
        } catch {
            errorMessage = error.localizedDescription
            isShowingError = true
            status = "Failed"
        }
    }

    private func makeRecord(
        _ algorithm: BenchmarkRecord.Algorithm,
        samples: BlurBenchmarkRunner.Samples,
        output: BlurBenchmarkRunner.Output,
        match: BlurStrengthMatcher.Result,
        metadata: BenchmarkRecord.Device,
        width: Int,
        height: Int,
        memoryBefore: UInt64?,
        memoryAfter: UInt64?
    ) -> BenchmarkRecord {
        BenchmarkRecord(
            version: 1, createdAt: Date(), device: metadata,
            workload: .init(
                width: width, height: height, pixelFormat: "bgra8Unorm", algorithm: algorithm,
                iterations: algorithm == .dualKawase ? iterations : nil,
                offset: algorithm == .dualKawase ? offset : nil,
                sigma: algorithm == .mpsGaussian ? match.sigma : nil,
                matchedSecondMoment: match.targetSecondMoment,
                normalizedRMSE: match.residualError,
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
            counts: .init(encoded: output.measuredIterations, completed: samples.gpuMilliseconds.count,
                          droppedNoCapacity: 0, droppedEncodingFailure: 0, droppedDeadline: 0),
            memory: .init(residentBytesBefore: memoryBefore, residentBytesAfter: memoryAfter,
                          peakResidentBytes: nil, allocationCount: nil)
        )
    }

    private static func deviceMetadata() throws -> BenchmarkRecord.Device {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlurBenchmarkRunner.RunnerError.metalUnavailable }
        let process = ProcessInfo.processInfo
        #if targetEnvironment(simulator)
        let environment: BenchmarkRecord.Environment = .simulator
        #else
        let environment: BenchmarkRecord.Environment = .device
        #endif
        return .init(
            model: sysctlString("hw.machine"), gpuName: device.name,
            gpuFamilies: supportedFamilies(device), osVersion: process.operatingSystemVersionString,
            osBuild: sysctlString("kern.osversion"), environment: environment,
            thermalState: thermalStateName(process.thermalState), minimumRefreshRate: 0,
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
        switch state { case .nominal: "nominal"; case .fair: "fair"; case .serious: "serious";
        case .critical: "critical"; @unknown default: "unknown" }
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
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}
