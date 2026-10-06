import Foundation
import RemoteCore

/// A TV that only exists in memory, so the whole UI runs in the simulator.
/// It records every command for tests.
public actor MockTVDriver: TVDriver {
    public static let platform = TVPlatform.demo

    public static let demoDevice = DeviceDescriptor(
        id: "demo/serial/demo-tv",
        name: "Demo TV",
        platform: .demo,
        host: "127.0.0.1",
        port: 0,
        model: "Simulated"
    )

    public nonisolated let device: DeviceDescriptor
    public private(set) var capabilities: TVCapabilities = [
        .dpad, .touchpad, .keyboard, .volume, .mute, .power, .apps, .appList, .keyHold, .mediaControls, .channels,
    ]
    public private(set) var sentCommands: [RemoteCommand] = []
    public private(set) var typedText = ""

    private let broadcaster = StateBroadcaster<ConnectionState>(.disconnected)
    private let latency: Duration
    private var failNextConnect: DriverError?

    public init(device: DeviceDescriptor = MockTVDriver.demoDevice, latency: Duration = .milliseconds(15)) {
        self.device = device
        self.latency = latency
    }

    public var state: AsyncStream<ConnectionState> { broadcaster.stream() }

    public func setCapabilities(_ capabilities: TVCapabilities) {
        self.capabilities = capabilities
    }

    public func failNextConnect(with error: DriverError) {
        failNextConnect = error
    }

    /// Simulates the TV going away, as a dropped Wi-Fi would.
    public func simulateDrop() {
        broadcaster.update(.error(.connectionLost))
    }

    public func connect() async throws {
        broadcaster.update(.connecting)
        try await Task.sleep(for: latency * 4)
        if let error = failNextConnect {
            failNextConnect = nil
            broadcaster.update(.error(error))
            throw error
        }
        broadcaster.update(.connected)
    }

    public func pair(code: String?) async throws -> PairingCredentials {
        try await connect()
        return .none(.demo)
    }

    public func send(_ key: RemoteKey) async throws {
        try await send(key, action: .press)
    }

    public func send(_ key: RemoteKey, action: KeyAction) async throws {
        try await simulate(.key(key, action))
        if key == .backspace, action == .press, !typedText.isEmpty { typedText.removeLast() }
    }

    public func sendText(_ text: String) async throws {
        try await simulate(.text(text))
        typedText += text
    }

    public func swipe(dx: Double, dy: Double) async throws {
        try await simulate(.swipe(dx: dx, dy: dy))
    }

    public func launchApp(_ id: String) async throws {
        try await simulate(.launch(appID: id))
    }

    public func listApps() async throws -> [TVApp] {
        try await Task.sleep(for: latency)
        return [
            TVApp(id: "demo.video", name: "Video"),
            TVApp(id: "demo.music", name: "Music"),
            TVApp(id: "demo.photos", name: "Photos"),
            TVApp(id: "demo.news", name: "News"),
            TVApp(id: "demo.games", name: "Games"),
            TVApp(id: "demo.settings", name: "Settings"),
        ]
    }

    public func heartbeat() async throws {
        guard broadcaster.current == .connected else { throw DriverError.connectionLost }
    }

    public func disconnect() async {
        broadcaster.update(.disconnected)
    }

    private func simulate(_ command: RemoteCommand) async throws {
        guard broadcaster.current == .connected else { throw DriverError.connectionLost }
        sentCommands.append(command)
        try await Task.sleep(for: latency)
    }
}
