import Synchronization

/// A fixed-capacity output store for workspaces that publish completed GPU frames.
/// Resource ownership, writer reservations, the retained latest frame, and independent
/// presenter readers are changed atomically by one small mutex-protected state machine.
final class SharedOutputFrames<Resource: Sendable>: Sendable {
    private struct SlotState: Sendable {
        var writerSequence: UInt64?
        var writerRevision: UInt64?
        var hasStoreHold = false
        var readerCount = 0
    }

    /// The slot array is mutable only while `SharedOutputFrames.state` is locked.
    private final class Generation: @unchecked Sendable {
        var id: UInt64
        let resources: [Resource]
        var slots: [SlotState]
        var isCurrent: Bool

        init(id: UInt64, resources: [Resource], isCurrent: Bool) {
            self.id = id
            self.resources = resources
            slots = resources.map { _ in SlotState() }
            self.isCurrent = isCurrent
        }

        var hasOutstandingOwnership: Bool {
            slots.contains { $0.writerSequence != nil || $0.hasStoreHold || $0.readerCount > 0 }
        }
    }

    private struct FrameReference: Sendable {
        let generationID: UInt64
        let slotIndex: Int
        let sequence: UInt64
    }

    private struct State: Sendable {
        var generations: [Generation]
        var currentGenerationID: UInt64 = 0
        var nextGenerationID: UInt64 = 0
        var nextSequence: UInt64 = 0
        var targetRevision: UInt64 = 0
        var latest: FrameReference?
        var isFinished = false
    }

    private struct RetiredGenerations: Sendable {
        var first: Generation?
        var second: Generation?
    }

    private enum WriterAcquisition: Sendable {
        case none
        case acquired(resource: Resource, generationID: UInt64, slotIndex: Int, sequence: UInt64, revision: UInt64)
    }

    private struct ReaderAcquisition: Sendable {
        let resource: Resource
        let generationID: UInt64
        let slotIndex: Int
        let sequence: UInt64
    }

    private let state: Mutex<State>

    init(resources: [Resource]) {
        precondition(resources.isEmpty || resources.count == 3, "Shared output capacity is fixed at three slots.")
        let generations = resources.isEmpty ? [] : [Generation(id: 0, resources: resources, isCurrent: true)]
        state = Mutex(State(generations: generations))
    }

    /// Reserves one existing writer slot immediately. Contention or exhaustion drops work.
    func acquireWriter(revision: UInt64 = 0) -> WriterLease? {
        guard let acquisition = state.withLockIfAvailable({ state in
            Self.reserveSlot(in: &state) { targetRevision in max(revision, targetRevision) }
        }) else {
            return nil
        }
        return makeWriterLease(acquisition)
    }

    /// Reserves a writer that publishes only if no invalidation advanced the target
    /// revision past `pinnedRevision`. Waits out lock contention, so only exhaustion drops
    /// work; meant for the off-main encode queue, where a short wait is harmless.
    func acquireWriter(pinnedRevision: UInt64) -> WriterLease? {
        let acquisition = state.withLock { state in
            Self.reserveSlot(in: &state) { _ in pinnedRevision }
        }
        return makeWriterLease(acquisition)
    }

    private static func reserveSlot(
        in state: inout State,
        revision resolveRevision: (UInt64) -> UInt64
    ) -> WriterAcquisition {
        guard !state.isFinished,
              let generation = state.generations.first(where: { $0.id == state.currentGenerationID }),
              let slotIndex = generation.slots.indices.first(where: { index in
                  let slot = generation.slots[index]
                  return slot.writerSequence == nil && !slot.hasStoreHold && slot.readerCount == 0
              })
        else {
            return .none
        }

        state.nextSequence &+= 1
        let sequence = state.nextSequence
        generation.slots[slotIndex].writerSequence = sequence
        let targetRevision = resolveRevision(state.targetRevision)
        generation.slots[slotIndex].writerRevision = targetRevision
        return .acquired(
            resource: generation.resources[slotIndex],
            generationID: generation.id,
            slotIndex: slotIndex,
            sequence: sequence,
            revision: targetRevision
        )
    }

    private func makeWriterLease(_ acquisition: WriterAcquisition) -> WriterLease? {
        guard case let .acquired(resource, generationID, slotIndex, sequence, revision) = acquisition else {
            return nil
        }
        return WriterLease(
            resource: resource,
            generationID: generationID,
            slotIndex: slotIndex,
            sequence: sequence,
            revision: revision,
            owner: self
        )
    }

    /// Atomically pins the current latest output for one presentation command buffer.
    func acquireLatest() -> ReadLease? {
        let acquisition = state.withLock { state -> ReaderAcquisition? in
            guard !state.isFinished,
                  let latest = state.latest,
                  let generation = state.generations.first(where: { $0.id == latest.generationID }),
                  generation.slots.indices.contains(latest.slotIndex),
                  generation.slots[latest.slotIndex].hasStoreHold
            else {
                return nil
            }

            generation.slots[latest.slotIndex].readerCount += 1
            return ReaderAcquisition(
                resource: generation.resources[latest.slotIndex],
                generationID: latest.generationID,
                slotIndex: latest.slotIndex,
                sequence: latest.sequence
            )
        }

        guard let acquisition else { return nil }
        return ReadLease(
            resource: acquisition.resource,
            generationID: acquisition.generationID,
            sequence: acquisition.sequence,
            owner: self,
            slotIndex: acquisition.slotIndex
        )
    }

    /// Adds a resource generation while retaining the old latest until replacement succeeds.
    /// At most the current and one retiring generation can coexist.
    @discardableResult
    func replaceResources(with resources: [Resource]) -> Bool {
        guard resources.count == 3 else { return false }
        let replacement = Generation(id: 0, resources: resources, isCurrent: true)

        let result = state.withLock { state -> (installed: Bool, retired: RetiredGenerations) in
            let retired = Self.collectRetiredGenerations(from: &state)
            guard !state.isFinished, state.generations.count < 2 else {
                return (false, retired)
            }

            state.nextGenerationID &+= 1
            replacement.id = state.nextGenerationID
            for generation in state.generations {
                generation.isCurrent = false
            }
            state.generations.append(replacement)
            state.currentGenerationID = replacement.id
            return (true, retired)
        }
        withExtendedLifetime(result.retired) {}
        return result.installed
    }

    /// Makes room for a requested replacement, retiring an unused superseded writer
    /// generation while keeping any last-good store/read holds alive.
    func prepareForResourceReplacement() -> Bool {
        let result = state.withLock { state -> (canInstall: Bool, retired: RetiredGenerations) in
            var retired = Self.collectRetiredGenerations(from: &state)
            if !state.isFinished, state.generations.count >= 2,
               let current = state.generations.first(where: { $0.id == state.currentGenerationID }),
               !current.hasOutstandingOwnership {
                current.isCurrent = false
                state.currentGenerationID = 0
                let newlyRetired = Self.collectRetiredGenerations(from: &state)
                if retired.first == nil { retired.first = newlyRetired.first }
                else { retired.second = newlyRetired.first }
                if retired.second == nil { retired.second = newlyRetired.second }
            }
            return (!state.isFinished && state.generations.count < 2, retired)
        }
        withExtendedLifetime(result.retired) {}
        return result.canInstall
    }

    func advanceTargetRevision() {
        state.withLock { state in state.targetRevision &+= 1 }
    }

    /// The current generation's resources, or none before the first replacement.
    var currentResources: [Resource] {
        state.withLock { state in
            state.generations.first { $0.id == state.currentGenerationID }?.resources ?? []
        }
    }

    var targetRevision: UInt64 { state.withLock { $0.targetRevision } }

    var isFinished: Bool { state.withLock { $0.isFinished } }

    /// Finishes input ownership, drops the retained-store hold, and rejects future work.
    /// Already acquired reader and writer leases remain valid until their own completion.
    func finish() {
        let retired = state.withLock { state -> RetiredGenerations in
            guard !state.isFinished else { return RetiredGenerations() }
            state.isFinished = true
            if let latest = state.latest,
               let generation = state.generations.first(where: { $0.id == latest.generationID }),
               generation.slots.indices.contains(latest.slotIndex) {
                generation.slots[latest.slotIndex].hasStoreHold = false
            }
            state.latest = nil
            for generation in state.generations {
                generation.isCurrent = false
            }
            return Self.collectRetiredGenerations(from: &state)
        }
        withExtendedLifetime(retired) {}
    }

    var availableWriterCount: Int {
        state.withLock { state in
            guard !state.isFinished,
                  let generation = state.generations.first(where: { $0.id == state.currentGenerationID })
            else {
                return 0
            }
            return generation.slots.reduce(into: 0) { count, slot in
                if slot.writerSequence == nil && !slot.hasStoreHold && slot.readerCount == 0 {
                    count += 1
                }
            }
        }
    }

    private func completeWriter(
        generationID: UInt64,
        slotIndex: Int,
        sequence: UInt64,
        revision: UInt64,
        success: Bool
    ) -> Bool {
        let result = state.withLock { state -> (published: Bool, retired: RetiredGenerations) in
            guard let generation = state.generations.first(where: { $0.id == generationID }),
                  generation.slots.indices.contains(slotIndex),
                  generation.slots[slotIndex].writerSequence == sequence,
                  generation.slots[slotIndex].writerRevision == revision
            else {
                return (false, Self.collectRetiredGenerations(from: &state))
            }

            generation.slots[slotIndex].writerSequence = nil
            generation.slots[slotIndex].writerRevision = nil
            var published = false
            if success,
               !state.isFinished,
               revision == state.targetRevision,
               generationID == state.currentGenerationID,
               sequence > (state.latest?.sequence ?? 0) {
                if let latest = state.latest,
                   let previousGeneration = state.generations.first(where: { $0.id == latest.generationID }),
                   previousGeneration.slots.indices.contains(latest.slotIndex) {
                    previousGeneration.slots[latest.slotIndex].hasStoreHold = false
                }
                generation.slots[slotIndex].hasStoreHold = true
                state.latest = FrameReference(
                    generationID: generationID,
                    slotIndex: slotIndex,
                    sequence: sequence
                )
                published = true
            }
            return (published, Self.collectRetiredGenerations(from: &state))
        }
        withExtendedLifetime(result.retired) {}
        return result.published
    }

    private func releaseReader(generationID: UInt64, slotIndex: Int) {
        let retired = state.withLock { state -> RetiredGenerations in
            guard let generation = state.generations.first(where: { $0.id == generationID }),
                  generation.slots.indices.contains(slotIndex),
                  generation.slots[slotIndex].readerCount > 0
            else {
                return RetiredGenerations()
            }
            generation.slots[slotIndex].readerCount -= 1
            return Self.collectRetiredGenerations(from: &state)
        }
        withExtendedLifetime(retired) {}
    }

    /// Removes idle retired generations, keeping removed resources alive until after unlock.
    private static func collectRetiredGenerations(from state: inout State) -> RetiredGenerations {
        var retired = RetiredGenerations()
        var index = 0
        while index < state.generations.count {
            let generation = state.generations[index]
            guard !generation.isCurrent, !generation.hasOutstandingOwnership else {
                index += 1
                continue
            }
            if retired.first == nil {
                retired.first = generation
            } else {
                retired.second = generation
            }
            state.generations.remove(at: index)
        }
        return retired
    }

    final class WriterLease: Sendable {
        let resource: Resource
        let generationID: UInt64
        let sequence: UInt64
        private let revision: UInt64
        private let slotIndex: Int
        private let owner: SharedOutputFrames<Resource>
        private let isCompleted = Mutex(false)

        fileprivate init(
            resource: Resource,
            generationID: UInt64,
            slotIndex: Int,
            sequence: UInt64,
            revision: UInt64,
            owner: SharedOutputFrames<Resource>
        ) {
            self.resource = resource
            self.generationID = generationID
            self.slotIndex = slotIndex
            self.sequence = sequence
            self.revision = revision
            self.owner = owner
        }

        /// Returns true only when this successful completion became the retained latest frame.
        @discardableResult
        func complete(success: Bool) -> Bool {
            let shouldComplete = isCompleted.withLock { completed in
                guard !completed else { return false }
                completed = true
                return true
            }
            guard shouldComplete else { return false }
            return owner.completeWriter(
                generationID: generationID,
                slotIndex: slotIndex,
                sequence: sequence,
                revision: revision,
                success: success
            )
        }

        func cancelBeforeSubmission() {
            _ = complete(success: false)
        }

        deinit {
            cancelBeforeSubmission()
        }
    }

    final class ReadLease: Sendable {
        let resource: Resource
        let generationID: UInt64
        let sequence: UInt64
        private let slotIndex: Int
        private let owner: SharedOutputFrames<Resource>
        private let lifetime: FrameLease

        fileprivate init(
            resource: Resource,
            generationID: UInt64,
            sequence: UInt64,
            owner: SharedOutputFrames<Resource>,
            slotIndex: Int
        ) {
            self.resource = resource
            self.generationID = generationID
            self.sequence = sequence
            self.slotIndex = slotIndex
            self.owner = owner
            lifetime = FrameLease { [weak owner] in
                owner?.releaseReader(generationID: generationID, slotIndex: slotIndex)
            }
        }

        func release() {
            lifetime.release()
        }
    }
}
