import Foundation
import Network

/// Exponential reconnect delays: 0.5 s, 1 s, 2 s, 4 s … capped at `maximum`.
public struct Backoff: Sendable, Equatable {
    public var base: Duration
    public var maximum: Duration

    public init(base: Duration = .milliseconds(500), maximum: Duration = .seconds(30)) {
        self.base = base
        self.maximum = maximum
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt, 0), 16)
        let delay = base * (1 << exponent)
        return min(delay, maximum)
    }
}

/// Keeps one driver connected: heartbeats, silent reconnects with backoff, and an
/// immediate retry when the Wi-Fi path changes or the app comes back to the foreground.
public actor KeepAlive {
    private let driver: any TVDriver
    private let heartbeatInterval: Duration
    private let backoff: Backoff
    private var stateTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectGeneration = 0
    private var pathMonitor: NWPathMonitor?
    private var lastPathWasUsable = true
    private var attempt = 0
    private var running = false

    public init(driver: any TVDriver, heartbeatInterval: Duration = .seconds(20), backoff: Backoff = Backoff()) {
        self.driver = driver
        self.heartbeatInterval = heartbeatInterval
        self.backoff = backoff
    }

    public func start() async {
        guard !running else { return }
        running = true
        let states = await driver.state
        stateTask = Task { [weak self] in
            for await state in states {
                await self?.handle(state)
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            Task { await self?.pathChanged(usable: usable) }
        }
        monitor.start(queue: DispatchQueue(label: "remote.keepalive.path"))
        pathMonitor = monitor
    }

    public func stop() {
        running = false
        stateTask?.cancel()
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        pathMonitor?.cancel()
        stateTask = nil
        heartbeatTask = nil
        reconnectTask = nil
        pathMonitor = nil
    }

    /// Reconnect right away, skipping the backoff. Call when the app returns to the foreground.
    public func reconnectNow() async {
        guard running else { return }
        if await driver.state.firstValue == .connected {
            // Probably still fine; a heartbeat proves it.
            await beat()
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        attempt = 0
        scheduleReconnect(immediately: true)
    }

    private func handle(_ state: ConnectionState) {
        switch state {
        case .connected:
            attempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            startHeartbeat()
        case .error(let error) where error.isTransient:
            heartbeatTask?.cancel()
            scheduleReconnect(immediately: false)
        case .disconnected:
            heartbeatTask?.cancel()
            scheduleReconnect(immediately: false)
        case .error, .connecting, .pairing:
            heartbeatTask?.cancel()
        }
    }

    private func pathChanged(usable: Bool) async {
        defer { lastPathWasUsable = usable }
        if usable && !lastPathWasUsable {
            await reconnectNow()
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.beat()
            }
        }
    }

    private func beat() async {
        do {
            try await driver.heartbeat()
        } catch {
            heartbeatTask?.cancel()
            scheduleReconnect(immediately: true)
        }
    }

    private func scheduleReconnect(immediately: Bool) {
        guard running, reconnectTask == nil else { return }
        reconnectGeneration += 1
        let generation = reconnectGeneration
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(skipFirstDelay: immediately, generation: generation)
        }
    }

    private func reconnectLoop(skipFirstDelay: Bool, generation: Int) async {
        var skipDelay = skipFirstDelay
        defer {
            // A newer loop may have replaced this one; only clear our own handle.
            if reconnectGeneration == generation { reconnectTask = nil }
        }
        while running && !Task.isCancelled {
            if !skipDelay {
                try? await Task.sleep(for: backoff.delay(forAttempt: attempt))
                guard !Task.isCancelled else { return }
            }
            skipDelay = false
            attempt += 1
            do {
                try await driver.connect()
                return
            } catch {
                if !DriverError(error).isTransient { return }
            }
        }
    }
}

extension AsyncStream where Element: Sendable {
    /// The first element, or nil if the stream finishes empty.
    public var firstValue: Element? {
        get async {
            for await value in self { return value }
            return nil
        }
    }
}
