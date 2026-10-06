import Foundation

/// One protocol implementation (Roku ECP, Android TV Remote v2, …) for one TV.
///
/// Drivers are actors, so all their state is isolated. The UI never awaits a driver
/// directly on a button press; it goes through `CommandQueue`.
public protocol TVDriver: Actor {
    static var platform: TVPlatform { get }

    nonisolated var device: DeviceDescriptor { get }

    /// A fresh stream on every access. It yields the current state first.
    var state: AsyncStream<ConnectionState> { get }
    var capabilities: TVCapabilities { get }

    func connect() async throws
    /// Two-step platforms (code on TV) call `startPairing()` first so the TV shows the code.
    func startPairing() async throws
    func pair(code: String?) async throws -> PairingCredentials
    func send(_ key: RemoteKey) async throws
    func send(_ key: RemoteKey, action: KeyAction) async throws
    func sendText(_ text: String) async throws
    func swipe(dx: Double, dy: Double) async throws
    func launchApp(_ id: String) async throws
    func listApps() async throws -> [TVApp]
    /// A cheap round trip used by `KeepAlive`. Throws if the TV is gone.
    func heartbeat() async throws
    func disconnect() async
}

extension TVDriver {
    public func startPairing() async throws {}

    public func send(_ key: RemoteKey, action: KeyAction) async throws {
        // Drivers without real key-down/up only understand discrete presses.
        if action != .up { try await send(key) }
    }

    public func swipe(dx: Double, dy: Double) async throws {
        throw DriverError.unsupported("touchpad gestures")
    }

    public func heartbeat() async throws {}
}

/// Fans one value out to any number of `AsyncStream` listeners and remembers the latest.
public final class StateBroadcaster<Value: Sendable>: Sendable {
    private struct Storage {
        var current: Value
        var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    }

    private let storage: Locked<Storage>

    public init(_ initial: Value) {
        storage = Locked(Storage(current: initial))
    }

    public var current: Value { storage.withLock { $0.current } }

    public func stream() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        storage.withLock {
            continuation.yield($0.current)
            $0.continuations[id] = continuation
        }
        continuation.onTermination = { [weak self] _ in
            self?.storage.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    public func send(_ value: Value) {
        let listeners = storage.withLock { state -> [AsyncStream<Value>.Continuation] in
            state.current = value
            return Array(state.continuations.values)
        }
        for listener in listeners { listener.yield(value) }
    }

    public func finish() {
        let listeners = storage.withLock { state -> [AsyncStream<Value>.Continuation] in
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for listener in listeners { listener.finish() }
    }
}

extension StateBroadcaster where Value: Equatable {
    /// Sends only when the value actually changed.
    public func update(_ value: Value) {
        if current != value { send(value) }
    }
}
