import os

/// A small lock-protected box. `Synchronization.Mutex` needs iOS 18, so this wraps
/// `OSAllocatedUnfairLock` for iOS 17.
public final class Locked<State>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var state: State

    public init(_ state: State) {
        self.state = state
    }

    public func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
