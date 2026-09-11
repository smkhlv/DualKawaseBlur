import Synchronization

/// A bounded, non-blocking pool for resources used by real-time frames.
final class FramePool<Resource: Sendable>: Sendable {
    /// Exactly-once ownership of one acquired resource.
    final class Lease: Sendable {
        let resource: Resource
        let slotID: Int

        private let lifetime: FrameLease

        fileprivate init(
            slot: Slot,
            onRelease: @escaping @Sendable () -> Void
        ) {
            resource = slot.resource
            slotID = slot.id
            lifetime = FrameLease(onRelease)
        }

        func release() {
            lifetime.release()
        }
    }

    fileprivate struct Slot: Sendable {
        let id: Int
        let resource: Resource
    }

    /// Reference storage keeps slot capacity fixed, so returning a resource cannot
    /// trigger copy-on-write allocation while the pool mutex is held.
    /// Mutable only while `FramePool.state` is held. The unchecked boundary lets a
    /// retired generation cross the mutex boundary solely to defer destruction.
    private final class Generation: @unchecked Sendable {
        var id: UInt64
        var slots: [Slot?]

        init(id: UInt64, resources: [Resource]) {
            self.id = id
            slots = resources.enumerated().map { index, resource in
                Slot(id: index, resource: resource)
            }
        }
    }

    private struct State {
        var nextGenerationID: UInt64
        var current: Generation
    }

    private enum Acquisition {
        case empty
        case acquired(Slot, generation: UInt64)
    }

    private let state: Mutex<State>

    init(resources: [Resource]) {
        state = Mutex(
            State(
                nextGenerationID: 0,
                current: Generation(id: 0, resources: resources)
            )
        )
    }

    /// Attempts to acquire immediately. Contention and exhaustion both drop the frame.
    func tryAcquire() -> Lease? {
        guard let acquisition = state.withLockIfAvailable({ state in
            guard let index = state.current.slots.lastIndex(where: { $0 != nil }) else {
                return Acquisition.empty
            }

            let slot = state.current.slots[index]!
            state.current.slots[index] = nil
            return Acquisition.acquired(slot, generation: state.current.id)
        }) else {
            return nil
        }

        guard case let .acquired(slot, generation) = acquisition else {
            return nil
        }

        return Lease(slot: slot) { [weak self] in
            self?.returnSlot(slot, generation: generation)
        }
    }

    /// Atomically installs a new resource generation. Retired available resources are
    /// kept alive until after the mutex is released, so their destructors may re-enter.
    func replace(with resources: [Resource]) {
        let replacement = Generation(id: 0, resources: resources)
        let retired = state.withLock { state -> Generation in
            state.nextGenerationID &+= 1
            replacement.id = state.nextGenerationID
            let retired = state.current
            state.current = replacement
            return retired
        }

        withExtendedLifetime(retired) {}
    }

    var availableCount: Int {
        state.withLock { state in
            state.current.slots.reduce(into: 0) { count, slot in
                if slot != nil {
                    count += 1
                }
            }
        }
    }

    private func returnSlot(_ slot: Slot, generation: UInt64) {
        state.withLock { state in
            guard
                state.current.id == generation,
                state.current.slots.indices.contains(slot.id),
                state.current.slots[slot.id] == nil
            else {
                return
            }

            state.current.slots[slot.id] = slot
        }
    }
}
