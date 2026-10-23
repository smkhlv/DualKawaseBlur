import Dispatch
import Metal
import os
import Synchronization

/// Encodes the shared session's latest frame on a scheduled serial job, off the caller's thread.
/// The mutex guards only small reads and writes; it is never held while encoding.
final class SharedBlurEncodeWorker: Sendable {
    /// Must run jobs serially, never two at once: the worker's workspace and signature state assume it.
    typealias Schedule = @Sendable (@escaping @Sendable () -> Void) -> Void

    private struct State {
        var configuration: BlurConfiguration
        var signature: SharedWorkspaceSignature?
        // Compiled once on the first workspace build and reused by every later rebuild.
        var pipelines: SplitRolePipelines?
        var isScheduled = false
    }

    private let source: MetalBlurFrameSource
    private let context: MetalContext
    private let outputs: SharedOutputFrames<SharedBlurWorkspace>
    private let schedule: Schedule
    private let onPublished: @Sendable () -> Void
    private let onDiagnostic: @Sendable (String) -> Void
    private let signposter = OSSignposter(subsystem: "DualKawaseBlur", category: .pointsOfInterest)
    private let state: Mutex<State>

    /// Runs jobs one at a time on a dedicated user-interactive serial queue.
    static func makeDefaultSchedule() -> Schedule {
        let queue = DispatchQueue(label: "DualKawaseBlur.encode", qos: .userInteractive)
        return { job in queue.async(execute: job) }
    }

    init(
        source: MetalBlurFrameSource,
        context: MetalContext,
        outputs: SharedOutputFrames<SharedBlurWorkspace>,
        configuration: BlurConfiguration,
        schedule: @escaping Schedule,
        onPublished: @escaping @Sendable () -> Void,
        onDiagnostic: @escaping @Sendable (String) -> Void
    ) {
        self.source = source
        self.context = context
        self.outputs = outputs
        self.schedule = schedule
        self.onPublished = onPublished
        self.onDiagnostic = onDiagnostic
        state = Mutex(State(configuration: configuration))
    }

    /// Schedules one encode job. Requests made while a job is still queued coalesce into it.
    func requestRender() {
        guard !outputs.isFinished else { return }
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.isScheduled else { return false }
            state.isScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        schedule { [weak self] in
            guard let self else { return }
            // Cleared before the take, so a frame published after this point gets its own job.
            state.withLock { $0.isScheduled = false }
            encodeLatest()
        }
    }

    /// Stores the configuration before advancing the revision, so a job that pins the new
    /// revision also reads the new configuration.
    func update(configuration: BlurConfiguration) {
        let changed = state.withLock { state -> Bool in
            guard state.configuration != configuration else { return false }
            state.configuration = configuration
            return true
        }
        guard changed else { return }
        outputs.advanceTargetRevision()
        // Iterations and offset are part of the signature: the split encoder bakes both in.
    }

    /// Pins the revision before the take: an invalidation that discards input after this
    /// point also rejects the frame taken here. Called only from the scheduled job.
    func encodeLatest() {
        let pinned = outputs.targetRevision
        guard let frame = source.takeLatest() else { return }
        encode(frame, pinnedRevision: pinned)
    }

    /// Transfers one taken frame into a command buffer that publishes only at `pinnedRevision`.
    func encode(_ frame: MetalBlurFrame, pinnedRevision: UInt64) {
        let interval = signposter.beginInterval("blur.encode")
        defer { signposter.endInterval("blur.encode", interval) }

        guard !outputs.isFinished else {
            frame.releaseAfterConsumption()
            return
        }
        let device = context.device
        let texture = frame.texture
        guard texture.device === device,
              texture.textureType == .type2D,
              !texture.isFramebufferOnly,
              texture.usage.isEmpty || texture.usage.contains(.shaderRead) else {
            frame.releaseAfterConsumption()
            return
        }

        let (configuration, signature) = state.withLock { ($0.configuration, $0.signature) }
        let nextSignature = SharedWorkspaceSignature(
            width: texture.width,
            height: texture.height,
            format: texture.pixelFormat,
            iterations: configuration.iterations,
            offset: configuration.offset
        )
        do {
            try configuration.validate(forWidth: texture.width, height: texture.height)
        } catch {
            frame.releaseAfterConsumption()
            return
        }

        if signature != nextSignature {
            guard outputs.prepareForResourceReplacement() else {
                frame.releaseAfterConsumption()
                onDiagnostic("drop: output generation still retiring")
                return
            }
            // The preflight may retire an idle superseded generation. If allocation then
            // fails, a later input must reconstruct the previously used signature too.
            state.withLock { $0.signature = nil }
            do {
                let resources = try makeWorkspaces(signature: nextSignature, configuration: configuration)
                guard outputs.replaceResources(with: resources) else {
                    frame.releaseAfterConsumption()
                    onDiagnostic("drop: output replacement generation busy")
                    return
                }
                state.withLock { $0.signature = nextSignature }
            } catch let error as DualKawaseBlurError {
                frame.releaseAfterConsumption()
                onDiagnostic("workspace error: \(error.localizedDescription)")
                return
            } catch {
                frame.releaseAfterConsumption()
                return
            }
        }

        guard let writer = outputs.acquireWriter(pinnedRevision: pinnedRevision) else {
            frame.releaseAfterConsumption()
            onDiagnostic("drop: three output writers busy")
            return
        }
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            writer.cancelBeforeSubmission()
            frame.releaseAfterConsumption()
            return
        }
        let workspace = writer.resource
        do {
            if case let .sharedEvent(event, value) = frame.readiness {
                commandBuffer.encodeWaitForEvent(event, value: value)
            }
            _ = try workspace.blur.encodeThroughLevelZero(source: texture, into: commandBuffer)
        } catch {
            writer.cancelBeforeSubmission()
            frame.releaseAfterConsumption()
            onDiagnostic("encode error: \(error.localizedDescription)")
            return
        }

        let onPublished = self.onPublished
        commandBuffer.addCompletedHandler { commandBuffer in
            frame.releaseAfterConsumption()
            guard writer.complete(success: commandBuffer.status == .completed) else { return }
            onPublished()
        }
        commandBuffer.commit()
    }

    /// Fails on the split schedule's guards before compiling a pipeline or allocating a texture.
    private func makeWorkspaces(
        signature: SharedWorkspaceSignature,
        configuration: BlurConfiguration
    ) throws -> [SharedBlurWorkspace] {
        let layout = try SplitRoleBlurEncoder.validateSupport(
            width: signature.width,
            height: signature.height,
            pixelFormat: signature.format,
            configuration: configuration
        )
        // Compiled outside the lock: `requestRender()` and `update` take it on the caller's thread.
        // Jobs run serially (see `Schedule`), so no other job can build the set in between.
        let pipelines: SplitRolePipelines
        if let cached = state.withLock({ $0.pipelines }) {
            pipelines = cached
        } else {
            pipelines = try SplitRolePipelines(context: context)
            state.withLock { $0.pipelines = pipelines }
        }
        return try (0..<3).map { _ in
            SharedBlurWorkspace(
                blur: try SplitRoleBlurEncoder(
                    pipelines: pipelines,
                    layout: layout,
                    width: signature.width,
                    height: signature.height,
                    pixelFormat: signature.format,
                    offset: configuration.offset,
                    device: context.device
                ),
                sourceWidth: signature.width,
                sourceHeight: signature.height
            )
        }
    }
}
