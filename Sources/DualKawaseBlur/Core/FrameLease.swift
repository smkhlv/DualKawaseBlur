import Synchronization

/// Owns a cleanup callback that may be consumed from any thread exactly once.
final class FrameLease: Sendable {
    private let action: Mutex<(@Sendable () -> Void)?>

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = Mutex(action)
    }

    func release() {
        let callback = action.withLock { storedAction in
            defer { storedAction = nil }
            return storedAction
        }

        // User code must never execute while the lease mutex is held.
        callback?()
    }

    deinit {
        release()
    }
}
