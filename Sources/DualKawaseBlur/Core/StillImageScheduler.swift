import Foundation

actor StillImageScheduler {
    struct Inspection: Sendable, Equatable {
        let registered: Int
        let active: Int
        let queued: Int
        let cancellationMarkers: Int
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let capacity: Int
    private var registered: Set<UUID> = []
    private var active: Set<UUID> = []
    private var queued: [Waiter] = []

    init(capacity: Int = 2) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func schedule<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        registered.insert(id)
        defer { finish(id) }
        return try await withTaskCancellationHandler {
            try await acquire(id)
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func inspection() -> Inspection {
        Inspection(registered: registered.count, active: active.count, queued: queued.count, cancellationMarkers: 0)
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if active.count < capacity {
            active.insert(id)
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queued.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func cancel(_ id: UUID) {
        guard registered.contains(id), let index = queued.firstIndex(where: { $0.id == id }) else { return }
        queued.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func finish(_ id: UUID) {
        registered.remove(id)
        if let index = queued.firstIndex(where: { $0.id == id }) {
            queued.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        guard active.remove(id) != nil else { return }
        promoteFirstQueued()
    }

    private func promoteFirstQueued() {
        guard !queued.isEmpty else { return }
        let waiter = queued.removeFirst()
        guard registered.contains(waiter.id) else {
            waiter.continuation.resume(throwing: CancellationError())
            promoteFirstQueued()
            return
        }
        active.insert(waiter.id)
        waiter.continuation.resume()
    }
}
