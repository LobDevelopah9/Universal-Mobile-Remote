import Foundation
import RemoteCore

/// Roku via ECP: stateless HTTP on port 8060, no pairing.
public actor RokuDriver: TVDriver {
    public static let platform = TVPlatform.roku
    public static let defaultPort = 8060

    public nonisolated let device: DeviceDescriptor
    public private(set) var capabilities: TVCapabilities = [
        .dpad, .keyboard, .apps, .appList, .appIcons, .keyHold, .mediaControls,
    ]

    private let client: ECPClient
    private let broadcaster = StateBroadcaster<ConnectionState>(.disconnected)

    public init(device: DeviceDescriptor) {
        self.device = device
        client = ECPClient(host: device.host, port: device.port == 0 ? Self.defaultPort : device.port)
    }

    /// For tests that point at a fake server.
    init(device: DeviceDescriptor, timeout: TimeInterval) {
        self.device = device
        client = ECPClient(host: device.host, port: device.port, timeout: timeout)
    }

    public var state: AsyncStream<ConnectionState> { broadcaster.stream() }

    public func connect() async throws {
        broadcaster.update(.connecting)
        do {
            let info = try await client.deviceInfo()
            if info.isTV {
                capabilities.formUnion([.volume, .mute, .power, .channels])
            } else {
                // Streaming sticks can't change TV volume over ECP, but most accept Power via HDMI-CEC.
                capabilities.insert(.power)
            }
            broadcaster.update(.connected)
        } catch {
            let driverError = DriverError(error)
            broadcaster.update(.error(driverError))
            throw driverError
        }
    }

    public func pair(code: String?) async throws -> PairingCredentials {
        try await connect()
        return .none(.roku)
    }

    public func send(_ key: RemoteKey) async throws {
        try await send(key, action: .press)
    }

    public func send(_ key: RemoteKey, action: KeyAction) async throws {
        guard let name = ECPKeyMap.name(for: key) else {
            throw DriverError.unsupported(key.accessibilityLabel)
        }
        try await run {
            switch action {
            case .press: try await client.keypress(name)
            case .down: try await client.keydown(name)
            case .up: try await client.keyup(name)
            }
        }
    }

    public func sendText(_ text: String) async throws {
        for character in text {
            if character == "\n" {
                try await send(.enter)
            } else {
                try await run { try await client.keypress(ECPKeyMap.literal(character)) }
            }
        }
    }

    public func launchApp(_ id: String) async throws {
        try await run { try await client.launch(id) }
    }

    public func listApps() async throws -> [TVApp] {
        try await run { try await client.apps() }
    }

    public func heartbeat() async throws {
        _ = try await run { try await client.deviceInfo() }
    }

    public func disconnect() async {
        broadcaster.update(.disconnected)
    }

    /// Runs one request and reflects a dead TV in the connection state.
    private func run<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            if broadcaster.current != .connected { broadcaster.update(.connected) }
            return value
        } catch {
            let driverError = DriverError(error)
            if driverError.isTransient || driverError == .rokuMobileControlDisabled {
                broadcaster.update(.error(driverError))
            }
            throw driverError
        }
    }
}
