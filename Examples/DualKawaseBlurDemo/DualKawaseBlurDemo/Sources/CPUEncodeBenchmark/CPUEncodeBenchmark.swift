import Darwin
import Foundation
import Metal
import QuartzCore
import SwiftUI
import UIKit
@_spi(Benchmark) import DualKawaseBlur

/// Opt-in, one-shot device route for `CPU_ENCODE_PROTOCOL.md` (v1) and, with
/// `--cpu-encode-protocol path-level-v2`, `PATH_LEVEL_PROTOCOL.md`. Each process runs one
/// qualification or one timing leg, writes `Documents/CPUEncodeBenchmark-<UUID>/report.json`,
/// prints `CPU_ENCODE_REPORT <folder>` and exits (0 passed, 2 failed). Never a production path.
enum CPUEncodeBenchmark {
    /// The first failed environment condition, named as the host journals it.
    enum Violation: String { case background, thermal, lowPower }

    enum Failure: Error {
        case arguments, metal, environment(Violation), thermalDeadline, timestamp

        /// Written to `failureReason`; `run_cpu_encode.NATIVE_REASONS` maps it to the journal reason.
        var reason: String {
            switch self {
            case .arguments: "arguments"
            case .metal: "metal"
            case let .environment(violation): violation.rawValue
            case .thermalDeadline: "thermalDeadline"
            case .timestamp: "timestamp"
            }
        }
    }

    static let flag = "--cpu-encode-benchmark"
    static let protocolID = "cpu-encode-blocks-v1"
    static let warmupCount = 1000, measuredCount = 3000
    /// Qualification's per-arm timing smoke: the timed legs' row loop, excluded from every analysis.
    static let smokeRowCount = 48

    enum Request: Equatable {
        case qualification
        case timing(arm: CPUEncodeArm, block: Int, attempt: Int, seriesSHA256: String)
        /// path-level-v2.
        case pathQualification
        case pathTiming(arm: PathLevelArm, block: Int, attempt: Int, seriesSHA256: String)

        var sessionLabel: String {
            switch self {
            case .qualification, .pathQualification: "qualification"
            case let .timing(arm, block, attempt, _): String(format: "b%02d-a%02d-%@", block, attempt, arm.rawValue)
            case let .pathTiming(arm, block, attempt, _): String(format: "b%02d-a%02d-%@", block, attempt, arm.rawValue)
            }
        }

        var isPathLevel: Bool {
            switch self {
            case .qualification, .timing: false
            case .pathQualification, .pathTiming: true
            }
        }

        var protocolID: String { isPathLevel ? PathLevelArm.protocolID : CPUEncodeBenchmark.protocolID }

        var method: String {
            switch self {
            case .qualification: "cpu-encode-qualification-v1"
            case .timing: "cpu-encode-leg-v1"
            case .pathQualification: "path-level-qualification-v2"
            case .pathTiming: "path-level-leg-v2"
            }
        }
    }

    /// Exact argument contract; anything missing, repeated or unknown is rejected. v1 takes no
    /// `--cpu-encode-protocol`; `path-level-v2` is the only value it accepts, and adds one argument.
    static func request(from arguments: [String]) -> Request? {
        var values: [String: String] = [:], cursor = 1, sawFlag = false
        let names: Set = ["--cpu-encode-mode", "--cpu-encode-arm", "--cpu-encode-block", "--cpu-encode-attempt",
                          "--cpu-encode-series", "--cpu-encode-protocol"]
        while cursor < arguments.count {
            let name = arguments[cursor]
            if name == flag, !sawFlag {
                sawFlag = true
            } else if names.contains(name), values[name] == nil, cursor + 1 < arguments.count {
                cursor += 1
                values[name] = arguments[cursor]
            } else {
                return nil
            }
            cursor += 1
        }
        guard sawFlag else { return nil }
        let pathLevel: Bool
        switch values["--cpu-encode-protocol"] {
        case nil: pathLevel = false
        case PathLevelArm.protocolID: pathLevel = true
        default: return nil
        }
        let selector = pathLevel ? 1 : 0
        switch values["--cpu-encode-mode"] {
        case "qualification" where values.count == 1 + selector:
            return pathLevel ? .pathQualification : .qualification
        case "timing" where values.count == 5 + selector:
            guard let armText = values["--cpu-encode-arm"],
                  let blockText = values["--cpu-encode-block"], let block = Int(blockText), String(block) == blockText,
                  (1...8).contains(block),
                  let attemptText = values["--cpu-encode-attempt"], let attempt = Int(attemptText),
                  String(attempt) == attemptText, (1...2).contains(attempt),
                  let series = values["--cpu-encode-series"], isHash(series) else { return nil }
            if pathLevel {
                guard let arm = PathLevelArm(rawValue: armText) else { return nil }
                return .pathTiming(arm: arm, block: block, attempt: attempt, seriesSHA256: series)
            }
            guard let arm = CPUEncodeArm(rawValue: armText) else { return nil }
            return .timing(arm: arm, block: block, attempt: attempt, seriesSHA256: series)
        default:
            return nil
        }
    }

    static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    struct Environment: Encodable {
        let time: Double
        let thermal: Int
        let foreground: Bool
        let lowPower: Bool
        var eligible: Bool { violation == nil }

        var violation: Violation? {
            if !foreground { return .background }
            if thermal != 0 { return .thermal }
            if lowPower { return .lowPower }
            return nil
        }

        func requireEligible() throws {
            if let violation { throw Failure.environment(violation) }
        }

        static func now() -> Environment {
            Environment(time: CACurrentMediaTime(), thermal: ProcessInfo.processInfo.thermalState.rawValue,
                foreground: UIApplication.shared.applicationState == .active,
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
    }

    struct Row: Encodable {
        let index: Int
        let inputIndex: Int
        let phase: String
        let timing: CPUEncodeTiming
        let before: Environment
        let after: Environment
    }

    struct Cooling: Encodable {
        let nominalContinuousSeconds: Double
        let elapsedSeconds: Double
        let pollSeconds = 0.5
        let noEncodes = true
        let checkpoints: [Environment]
    }

    /// One arm's qualification timing smoke, audited on the host exactly like a timed leg's rows.
    /// v1 records the arm's output texture; path-level-v2 records `pathOutput`.
    struct TimingSmoke: Encodable {
        var outputTextureUsage: UInt?
        var outputStorageMode: UInt?
        var pathOutput: PathOutput?
        var timingStart: Double?
        var timingEnd: Double?
        var rows: [Row] = []
    }

    struct QualificationCheck: Encodable {
        let fixture: String
        let sourceSHA256: String
        let outputSHA256: [String: String]
        /// v1: max per-channel |X − O|, alpha included; the gate is ≤ 1 for S and S4.
        var differenceVersusO: [String: Int]?
        /// path-level-v2: max per-channel |X − SC| of the composite, alpha included; the gate is ≤ 1 for SH only.
        var differenceVersusSC: [String: Int]?
    }

    struct Report: Encodable {
        let method: String
        var protocolID = CPUEncodeBenchmark.protocolID
        let sessionLabel: String
        let processSessionUUID = UUID().uuidString.lowercased()
        let width = CPUEncodeCorpus.width
        let height = CPUEncodeCorpus.height
        let pixelFormat = "bgra8Unorm"
        let iterations = 5
        let offset = 5
        let sigma = Double(CPUEncodeArm.sigma)
        let mpsOptions = "allowReducedPrecision"
        let hardware: String
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let gpu: String
        let s4Compiled = CPUEncodeArm.s4Compiled
        /// Build identity: the host compares both hashes with the frozen app and requires Release.
        let appExecutableSHA256 = CPUEncodeBenchmark.fileSHA256(Bundle.main.executableURL)
        let metallibSHA256 = CPUEncodeBenchmark.fileSHA256(
            Bundle.main.bundleURL.appendingPathComponent("DualKawaseBlur_DualKawaseBlur.bundle/default.metallib"))
        let debugBuild = CPUEncodeBenchmark.isDebugBuild
        let endToEndMeasured = false
        let automaticPromotion = false
        // path-level-v2 only (nil, so absent, in v1 reports): the composite every path ends with.
        var compositeBaseColor: [Double]?
        var compositeMapping: String?
        var corpusManifestSHA256: String?
        var completed = false
        var failure: String?
        /// `Failure.reason`, or "other" for any error outside this route's own failures.
        var failureReason: String?
        var failureEnvironment: Environment?
        // Qualification only.
        var arms: [String] = []
        var photoFixturesIncluded: Bool?
        var checks: [QualificationCheck] = []
        var sQualityPassed: Bool?
        var s4QualityPassed: Bool?
        var shQualityPassed: Bool?
        var expectedOutputSHA256: [String: [String: String]] = [:]
        var timingSmokeCooling: Cooling?
        var timingSmoke: [String: TimingSmoke] = [:]
        // Timing only.
        var arm: String?
        var block: Int?
        var attempt: Int?
        var seriesSHA256: String?
        var warmupCount: Int?
        var measuredCount: Int?
        var outputTextureUsage: UInt?
        var outputStorageMode: UInt?
        var pathOutput: PathOutput?
        var cooling: Cooling?
        var outputSHA256Before: [String: String]?
        var outputSHA256After: [String: String]?
        var timingStart: Double?
        var timingEnd: Double?
        var rows: [Row]?
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Nil when the file is missing or unreadable, which the host audit rejects as another build.
    static func fileSHA256(_ url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return CPUEncodeCorpus.hash(data)
    }

    static func run(_ request: Request) async -> (folder: String, passed: Bool) {
        let device = MTLCreateSystemDefaultDevice()
        var report = Report(method: request.method, protocolID: request.protocolID,
            sessionLabel: request.sessionLabel, hardware: hardware(), gpu: device?.name ?? "none")
        if request.isPathLevel {
            report.compositeBaseColor = (0..<4).map { Double(PathLevelArm.baseColor[$0]) }
            report.compositeMapping = PathLevelArm.compositeMapping
        }
        do {
            guard let device, let queue = device.makeCommandQueue() else { throw Failure.metal }
            let corpus = try CPUEncodeCorpus()
            report.corpusManifestSHA256 = corpus.manifestSHA256
            switch request {
            case .qualification:
                try await qualify(corpus: corpus, device: device, queue: queue, report: &report)
            case let .timing(arm, block, attempt, series):
                report.arm = arm.rawValue; report.block = block; report.attempt = attempt; report.seriesSHA256 = series
                try await time(arm, corpus: corpus, device: device, queue: queue, report: &report)
            case .pathQualification:
                try await qualifyPaths(corpus: corpus, device: device, queue: queue, report: &report)
            case let .pathTiming(arm, block, attempt, series):
                report.arm = arm.rawValue; report.block = block; report.attempt = attempt; report.seriesSHA256 = series
                try await timePath(arm, corpus: corpus, device: device, queue: queue, report: &report)
            }
            report.completed = true
        } catch {
            report.failure = String(describing: error)
            report.failureReason = (error as? Failure)?.reason ?? "other"
            report.failureEnvironment = .now()
        }
        let folder = "CPUEncodeBenchmark-\(UUID().uuidString)"
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let url = documents.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url.appendingPathComponent("report.json"), options: .atomic)
        } catch {
            return ("", false)
        }
        let passed = report.completed && (request != .qualification || report.sQualityPassed == true)
            && (request != .pathQualification || report.shQualityPassed == true)
        return (folder, passed)
    }

    // MARK: Qualification

    /// Every fixture through every available arm from the same source texture; S and S4 must stay
    /// within 1/255 of O on every channel. Also records each arm's Sphere output hashes for the
    /// timing legs' output guards. Then settles once and runs every arm's timing smoke over the eight
    /// Sphere sources through the timed legs' row loop, so both clock domains and the cooling path run
    /// before freeze. The smoke rows are audited like a leg's and never analyzed.
    private static func qualify(corpus: CPUEncodeCorpus, device: MTLDevice, queue: MTLCommandQueue,
                                report: inout Report) async throws {
        let (fixtures, photos) = try corpus.qualificationFixtures()
        report.photoFixturesIncluded = photos
        let staging = try CPUEncodeTextures.texture(device, .shared, .shaderRead)
        let source = try CPUEncodeTextures.texture(device, .private, .shaderRead)
        var arms: [CPUEncodeArm] = [.O, .S, .L]
        if CPUEncodeArm.s4Compiled { arms.append(.S4) }
        report.arms = arms.map(\.rawValue)
        var outputs: [String: MTLTexture] = [:], reads: [String: MTLTexture] = [:]
        for arm in arms {
            outputs[arm.rawValue] = try CPUEncodeTextures.texture(device, .private, arm.outputUsage)
            reads[arm.rawValue] = try CPUEncodeTextures.texture(device, .shared, [])
        }
        var sphereSources: [MTLTexture] = []
        for input in try corpus.sphereSequence() {
            sphereSources.append(try await CPUEncodeTextures.privateSource(input.pixels, device: device, queue: queue,
                staging: staging))
        }
        let resident = [source] + sphereSources + arms.compactMap { outputs[$0.rawValue] }
        let submitters = try Dictionary(uniqueKeysWithValues: arms.map {
            ($0.rawValue, try $0.makeSubmitter(device: device, queue: queue, textures: resident))
        })
        let rig = QualificationRig(arms: report.arms, source: source, staging: staging, destinations: outputs,
                                   reads: reads, submitters: submitters, sphereSources: sphereSources)
        for (fixture, check) in try await rig.run(fixtures, reference: CPUEncodeArm.O.rawValue, corpus: corpus,
                                                    queue: queue, report: &report) {
            report.checks.append(QualificationCheck(fixture: fixture.name, sourceSHA256: check.sourceSHA256,
                outputSHA256: check.hashes, differenceVersusO: check.differences))
        }
        report.sQualityPassed = report.checks.allSatisfy { ($0.differenceVersusO?["S"] ?? 256) <= 1 }
        if arms.contains(.S4) {
            report.s4QualityPassed = report.checks.allSatisfy { ($0.differenceVersusO?["S4"] ?? 256) <= 1 }
        }

        try await rig.smoke(report: &report) { arm, output in
            TimingSmoke(outputTextureUsage: output.usage.rawValue, outputStorageMode: output.storageMode.rawValue)
        }
    }

    /// path-level-v2: every fixture through LC, SC and SH (blur + composite) from the same source texture,
    /// reading back each arm's composite target; SH's composite must stay within 1/255 of SC's on every
    /// channel, and LC's difference from SC is recorded only. Then the same cooling and timing smoke as v1.
    private static func qualifyPaths(corpus: CPUEncodeCorpus, device: MTLDevice, queue: MTLCommandQueue,
                                     report: inout Report) async throws {
        let (fixtures, photos) = try corpus.qualificationFixtures()
        report.photoFixturesIncluded = photos
        let staging = try CPUEncodeTextures.texture(device, .shared, .shaderRead)
        let source = try CPUEncodeTextures.texture(device, .private, .shaderRead)
        let arms = PathLevelArm.allCases
        report.arms = arms.map(\.rawValue)
        var targets: [String: MTLTexture] = [:], reads: [String: MTLTexture] = [:]
        for arm in arms {
            targets[arm.rawValue] = try CPUEncodeTextures.texture(device, .private, PathLevelArm.compositeUsage)
            reads[arm.rawValue] = try CPUEncodeTextures.texture(device, .shared, [])
        }
        var sphereSources: [MTLTexture] = []
        for input in try corpus.sphereSequence() {
            sphereSources.append(try await CPUEncodeTextures.privateSource(input.pixels, device: device, queue: queue,
                staging: staging))
        }
        let composite = try BenchmarkOpaqueCompositeEncoder(device: device)
        let paths = try Dictionary(uniqueKeysWithValues: arms.map {
            ($0.rawValue, try $0.makePath(device: device, composite: composite))
        })
        let rig = QualificationRig(arms: report.arms, source: source, staging: staging, destinations: targets,
            reads: reads, submitters: paths.mapValues { $0.makeSubmitter(queue: queue) }, sphereSources: sphereSources)
        for (fixture, check) in try await rig.run(fixtures, reference: PathLevelArm.SC.rawValue, corpus: corpus,
                                                    queue: queue, report: &report) {
            report.checks.append(QualificationCheck(fixture: fixture.name, sourceSHA256: check.sourceSHA256,
                outputSHA256: check.hashes, differenceVersusSC: check.differences))
        }
        report.shQualityPassed = report.checks.allSatisfy { ($0.differenceVersusSC?["SH"] ?? 256) <= 1 }

        try await rig.smoke(report: &report) { arm, target in
            TimingSmoke(pathOutput: paths[arm]?.record(target: target))
        }
    }

    /// The fixture loop and the timing smoke both qualifications share. Arms are keyed by raw value.
    private struct QualificationRig {
        struct Check {
            let sourceSHA256: String
            let hashes: [String: String]
            /// Max per-channel difference from the reference arm, for every other arm.
            let differences: [String: Int]
        }

        let arms: [String]
        let source: MTLTexture
        let staging: MTLTexture
        /// What each arm's submitter writes; read back for hashes and differences.
        let destinations: [String: MTLTexture]
        let reads: [String: MTLTexture]
        let submitters: [String: CPUEncodeSubmitter]
        let sphereSources: [MTLTexture]

        /// Uploads each fixture into `source`, runs every arm once from it, reads back every destination,
        /// and records the Sphere output hashes the timing legs' guards reproduce.
        func run(_ fixtures: [CPUEncodeCorpus.Fixture], reference: String, corpus: CPUEncodeCorpus,
                 queue: MTLCommandQueue, report: inout Report) async throws -> [(CPUEncodeCorpus.Fixture, Check)] {
            let sequence = Set(corpus.manifest.primarySequence)
            var checks: [(CPUEncodeCorpus.Fixture, Check)] = []
            for fixture in fixtures {
                try Task.checkCancellation()
                CPUEncodeTextures.replace(fixture.pixels, into: staging)
                guard let upload = queue.makeCommandBuffer(), let blit = upload.makeBlitCommandEncoder() else { throw Failure.metal }
                CPUEncodeTextures.copy(staging, to: source, using: blit)
                blit.endEncoding()
                try await CPUEncodeTextures.finish(upload)
                var pixels: [String: Data] = [:]
                for arm in arms {
                    guard let submitter = submitters[arm], let output = destinations[arm], let read = reads[arm] else { throw Failure.metal }
                    let timing = try await submitter.submit(source: source, destination: output)
                    guard timing.gpuSucceeded else { throw Failure.metal }
                    guard let readback = queue.makeCommandBuffer(), let copy = readback.makeBlitCommandEncoder() else { throw Failure.metal }
                    CPUEncodeTextures.copy(output, to: read, using: copy)
                    copy.endEncoding()
                    try await CPUEncodeTextures.finish(readback)
                    pixels[arm] = CPUEncodeTextures.bytes(read)
                }
                guard let base = pixels[reference] else { throw Failure.metal }
                var hashes: [String: String] = [:], differences: [String: Int] = [:]
                for arm in arms {
                    guard let bytes = pixels[arm] else { throw Failure.metal }
                    let hash = CPUEncodeCorpus.hash(bytes)
                    hashes[arm] = hash
                    if arm != reference { differences[arm] = CPUEncodeTextures.maxDifference(bytes, base) }
                    if sequence.contains(fixture.name) { report.expectedOutputSHA256[arm, default: [:]][fixture.name] = hash }
                }
                checks.append((fixture, Check(sourceSHA256: CPUEncodeCorpus.hash(fixture.pixels), hashes: hashes,
                                              differences: differences)))
            }
            return checks
        }

        /// Settles once, then every arm's 48 smoke rows through the timed legs' row loop.
        func smoke(report: inout Report, record: (String, MTLTexture) -> TimingSmoke) async throws {
            report.timingSmokeCooling = try await CPUEncodeBenchmark.cooling()
            for arm in arms {
                guard let submitter = submitters[arm], let output = destinations[arm] else { throw Failure.metal }
                var smoke = record(arm, output)
                defer { report.timingSmoke[arm] = smoke }
                smoke.timingStart = CACurrentMediaTime()
                try await CPUEncodeBenchmark.timedRows(CPUEncodeBenchmark.smokeRowCount, phase: { _ in "smoke" },
                    submitter: submitter, sources: sphereSources, output: output, rows: &smoke.rows)
                smoke.timingEnd = CACurrentMediaTime()
            }
        }
    }

    // MARK: Timing

    private static func cooling() async throws -> Cooling {
        let start = CACurrentMediaTime()
        var nominalStart: Double?
        var checkpoints: [Environment] = []
        while true {
            try Task.checkCancellation()
            let state = Environment.now()
            checkpoints.append(state)
            guard state.time - start <= 300 else { throw Failure.thermalDeadline }
            if state.eligible {
                let since = nominalStart ?? state.time
                nominalStart = since
                if state.time - since >= 20 {
                    return Cooling(nominalContinuousSeconds: state.time - since, elapsedSeconds: state.time - start,
                        checkpoints: checkpoints)
                }
            } else {
                nominalStart = nil
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// One fresh-process leg: settle, prepare, guard outputs, 1000 warmup + 3000 measured blurs over
    /// the eight Sphere inputs (`index % 8`), guard outputs again. Any environment failure stops the leg;
    /// rows are never dropped.
    private static func time(_ arm: CPUEncodeArm, corpus: CPUEncodeCorpus, device: MTLDevice,
                             queue: MTLCommandQueue, report: inout Report) async throws {
        try await leg(corpus: corpus, device: device, queue: queue, report: &report) { sources, report in
            let output = try CPUEncodeTextures.texture(device, .private, arm.outputUsage)
            let read = try CPUEncodeTextures.texture(device, .shared, [])
            report.outputTextureUsage = output.usage.rawValue
            report.outputStorageMode = output.storageMode.rawValue
            let submitter = try arm.makeSubmitter(device: device, queue: queue, textures: sources + [output])
            return (output, read, submitter, nil)
        }
    }

    /// path-level-v2: the same leg procedure; each row is the arm's blur plus the composite into the
    /// private full-size target, whose bytes the output guards hash.
    private static func timePath(_ arm: PathLevelArm, corpus: CPUEncodeCorpus, device: MTLDevice,
                                 queue: MTLCommandQueue, report: inout Report) async throws {
        try await leg(corpus: corpus, device: device, queue: queue, report: &report) { _, _ in
            let target = try CPUEncodeTextures.texture(device, .private, PathLevelArm.compositeUsage)
            let read = try CPUEncodeTextures.texture(device, .shared, [])
            let path = try arm.makePath(device: device, composite: BenchmarkOpaqueCompositeEncoder(device: device))
            // Recorded after the first guard has run the path once.
            return (target, read, path.makeSubmitter(queue: queue), { $0.pathOutput = path.record(target: target) })
        }
    }

    private typealias LegSetup = (output: MTLTexture, read: MTLTexture, submitter: CPUEncodeSubmitter,
                                  afterFirstGuard: ((inout Report) -> Void)?)

    /// The one leg procedure. `prepare` allocates the arm's output (what each row writes and the guards
    /// hash), its readback texture and submitter, after the settling interval and the source uploads.
    private static func leg(corpus: CPUEncodeCorpus, device: MTLDevice, queue: MTLCommandQueue, report: inout Report,
                            prepare: ([MTLTexture], inout Report) throws -> LegSetup) async throws {
        report.warmupCount = warmupCount
        report.measuredCount = measuredCount
        // No blur or upload work during the symmetric settling interval.
        report.cooling = try await cooling()
        let inputs = try corpus.sphereSequence()
        let staging = try CPUEncodeTextures.texture(device, .shared, .shaderRead)
        var sources: [MTLTexture] = []
        for input in inputs {
            sources.append(try await CPUEncodeTextures.privateSource(input.pixels, device: device, queue: queue, staging: staging))
        }
        let (output, read, submitter, afterFirstGuard) = try prepare(sources, &report)

        func outputHashes() async throws -> [String: String] {
            var hashes: [String: String] = [:]
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                try Environment.now().requireEligible()
                let timing = try await submitter.submit(source: sources[index], destination: output)
                guard timing.gpuSucceeded, let buffer = queue.makeCommandBuffer(),
                      let blit = buffer.makeBlitCommandEncoder() else { throw Failure.metal }
                CPUEncodeTextures.copy(output, to: read, using: blit)
                blit.endEncoding()
                try await CPUEncodeTextures.finish(buffer)
                try Environment.now().requireEligible()
                hashes[input.name] = CPUEncodeCorpus.hash(CPUEncodeTextures.bytes(read))
            }
            return hashes
        }
        // The host compares these to the qualification receipt; a mismatch is a fatal quality failure.
        report.outputSHA256Before = try await outputHashes()
        afterFirstGuard?(&report)

        var rows: [Row] = []
        report.timingStart = CACurrentMediaTime()
        defer { report.rows = rows }
        try await timedRows(warmupCount + measuredCount, phase: { $0 < warmupCount ? "warmup" : "measured" },
            submitter: submitter, sources: sources, output: output, rows: &rows)
        report.timingEnd = CACurrentMediaTime()
        report.outputSHA256After = try await outputHashes()
    }

    /// The one row loop of timing legs and the qualification smoke: environment before and after
    /// every blur, one drained blur per row over `sources` in `index % count` order. The first
    /// violation or bad timestamp stops the loop; rows are never dropped.
    private static func timedRows(_ count: Int, phase: (Int) -> String, submitter: CPUEncodeSubmitter,
                                  sources: [MTLTexture], output: MTLTexture, rows: inout [Row]) async throws {
        rows.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            let before = Environment.now()
            try before.requireEligible()
            let timing = try await submitter.submit(source: sources[index % sources.count], destination: output)
            let after = Environment.now()
            rows.append(Row(index: index, inputIndex: index % sources.count, phase: phase(index), timing: timing,
                before: before, after: after))
            guard timing.gpuSucceeded, timing.gpuStart.isFinite, timing.gpuEnd.isFinite, 0 < timing.gpuStart,
                  timing.gpuStart < timing.gpuEnd, timing.encodeStart < timing.encodeEnd else { throw Failure.timestamp }
            try after.requireEligible()
        }
    }

    private static func hardware() -> String {
        var info = utsname()
        uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}

/// Runs the requested leg once, prints the report marker and exits the process.
struct CPUEncodeBenchmarkView: View {
    let request: CPUEncodeBenchmark.Request?
    @State private var status = "Preparing CPU encode benchmark…"

    var body: some View {
        Text(status)
            .padding()
            .task {
                guard let request else {
                    status = "Invalid CPU encode benchmark arguments."
                    print("CPU_ENCODE_REPORT_FAILED arguments")
                    fflush(stdout)
                    exit(2)
                }
                status = "Running \(request.sessionLabel)… keep the app in the foreground."
                let result = await CPUEncodeBenchmark.run(request)
                print(result.folder.isEmpty ? "CPU_ENCODE_REPORT_FAILED export" : "CPU_ENCODE_REPORT \(result.folder)")
                fflush(stdout)
                exit(result.passed ? 0 : 2)
            }
    }
}
