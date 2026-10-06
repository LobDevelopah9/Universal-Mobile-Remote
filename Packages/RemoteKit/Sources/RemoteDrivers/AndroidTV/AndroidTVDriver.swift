import Foundation
import os
import RemoteCore
import SwiftProtobuf

/// Android TV / Google TV via the Android TV Remote Service protocol v2.
///
/// Pairing runs on port 6467 (Polo); commands on 6466. Both are TLS with our client
/// certificate. The TV's remote-port certificate is pinned the first time we connect
/// after pairing.
public actor AndroidTVDriver: TVDriver {
    public static let platform = TVPlatform.androidTV
    public static let remotePort = 6466
    public static let pairingPort = 6467
    public static let pinKey = "serverCertSHA256"

    public nonisolated let device: DeviceDescriptor
    public private(set) var capabilities: TVCapabilities = [
        .dpad, .keyboard, .apps, .keyHold, .mediaControls, .volume, .mute, .power, .channels,
    ]

    private static let logger = Logger(subsystem: "com.example.remote", category: "androidtv")
    private static let idleTimeout: Duration = .seconds(16)
    private static let exchangeTimeout: Duration = .seconds(10)

    private let clientName: String
    private let broadcaster = StateBroadcaster<ConnectionState>(.disconnected)
    private var credentials: PairingCredentials?

    private var channel: TLSChannel?
    private var receiveTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, any Error>?
    private var activeFeatures: Int32 = 0

    private var imeActive = false
    private var imeCounter: Int32 = 0
    private var fieldCounter: Int32 = 0
    private var typedText = ""

    private var pairingChannel: TLSChannel?

    public init(device: DeviceDescriptor, credentials: PairingCredentials?, clientName: String = "Remote") {
        self.device = device
        self.credentials = credentials
        self.clientName = clientName
    }

    public var state: AsyncStream<ConnectionState> { broadcaster.stream() }

    // MARK: Connection

    public func connect() async throws {
        guard let credentials else {
            broadcaster.update(.error(.pairingRequired))
            throw DriverError.pairingRequired
        }
        teardown()
        broadcaster.update(.connecting)
        do {
            let identity = try ClientIdentity.shared()
            let channel = TLSChannel(
                host: device.host,
                port: Self.remotePort,
                identity: identity,
                pinnedCertificateSHA256: credentials.values[Self.pinKey]
            )
            try await channel.open()
            self.channel = channel
            startReceiving(on: channel)
            try await waitForRemoteStart()
            if credentials.values[Self.pinKey] == nil, let der = channel.peerCertificateDER {
                self.credentials?.values[Self.pinKey] = TLSChannel.fingerprint(der)
            }
            broadcaster.update(.connected)
        } catch {
            let driverError = DriverError(error)
            teardown()
            broadcaster.update(.error(driverError))
            throw driverError
        }
    }

    public func disconnect() async {
        teardown()
        closePairing()
        broadcaster.update(.disconnected)
    }

    public func heartbeat() async throws {
        // The TV pings every ~5 s and the watchdog catches silence, so nothing to send.
        guard channel != nil else { throw DriverError.connectionLost }
    }

    private func startReceiving(on channel: TLSChannel) {
        receiveTask = Task { [weak self] in
            do {
                while let frame = try await channel.receive() {
                    await self?.handle(frame, from: channel)
                }
                await self?.connectionEnded(DriverError.connectionLost, on: channel)
            } catch {
                await self?.connectionEnded(error, on: channel)
            }
        }
        resetWatchdog()
    }

    private func waitForRemoteStart() async throws {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            await self?.failStart(DriverError.timeout)
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            startWaiter = continuation
        }
    }

    private func failStart(_ error: any Error) {
        startWaiter?.resume(throwing: error)
        startWaiter = nil
    }

    /// Ignores stale callbacks from a channel that has already been replaced.
    private func connectionEnded(_ error: any Error, on source: TLSChannel) {
        guard let channel, channel === source else { return }
        failStart(error)
        teardown()
        broadcaster.update(.error(DriverError(error)))
    }

    private func resetWatchdog() {
        watchdog?.cancel()
        guard let current = channel else { return }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: AndroidTVDriver.idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.connectionEnded(DriverError.connectionLost, on: current)
        }
    }

    private func teardown() {
        failStart(DriverError.connectionLost)
        watchdog?.cancel()
        watchdog = nil
        receiveTask?.cancel()
        receiveTask = nil
        channel?.close()
        channel = nil
        imeActive = false
        typedText = ""
    }

    private func handle(_ frame: Data, from source: TLSChannel) async {
        guard source === channel else { return }
        resetWatchdog()
        let message: Remote_RemoteMessage
        do {
            message = try Remote_RemoteMessage(serializedBytes: frame)
        } catch {
            Self.logger.debug("Unparseable remote frame: \(error.localizedDescription)")
            return
        }

        if message.hasRemoteConfigure {
            let reply = AndroidTVMessages.configureResponse(tvFeatures: message.remoteConfigure.code1)
            activeFeatures = reply.remoteConfigure.code1
            applyFeatures(AndroidTVFeatures(rawValue: activeFeatures))
            try? await write(reply)
        } else if message.hasRemoteSetActive {
            try? await write(AndroidTVMessages.setActive(activeFeatures))
        } else if message.hasRemotePingRequest {
            try? await write(AndroidTVMessages.pingResponse(message.remotePingRequest.val1))
        } else if message.hasRemoteStart {
            startWaiter?.resume()
            startWaiter = nil
        } else if message.hasRemoteImeBatchEdit {
            imeActive = true
            imeCounter = message.remoteImeBatchEdit.imeCounter
            fieldCounter = message.remoteImeBatchEdit.fieldCounter
        } else if message.hasRemoteImeShowRequest {
            imeActive = true
            typedText = message.remoteImeShowRequest.remoteTextFieldStatus.value
        } else if message.hasRemoteError {
            Self.logger.error("TV reported an error")
        }
    }

    private func applyFeatures(_ features: AndroidTVFeatures) {
        var updated: TVCapabilities = [.dpad, .keyHold, .mediaControls, .channels]
        if features.contains(.key) { updated.formUnion([.volume, .mute, .power]) }
        if features.contains(.appLink) { updated.insert(.apps) }
        // Without IME, text still works through per-character key codes.
        updated.insert(.keyboard)
        capabilities = updated
    }

    private func write(_ message: Remote_RemoteMessage) async throws {
        guard let channel else { throw DriverError.connectionLost }
        try await channel.send(try AndroidTVMessages.framed(message))
    }

    // MARK: Commands

    public func send(_ key: RemoteKey) async throws {
        try await send(key, action: .press)
    }

    public func send(_ key: RemoteKey, action: KeyAction) async throws {
        if key == .backspace, action == .press, imeActive, !typedText.isEmpty {
            typedText.removeLast()
            if !typedText.isEmpty {
                try await write(AndroidTVMessages.imeText(typedText, imeCounter: imeCounter, fieldCounter: fieldCounter))
                return
            }
        }
        let direction: Remote_RemoteDirection = switch action {
        case .press: .short
        case .down: .startLong
        case .up: .endLong
        }
        try await write(AndroidTVMessages.key(AndroidTVKeyMap.code(for: key), direction: direction))
    }

    public func sendText(_ text: String) async throws {
        guard !text.isEmpty else { return }
        if imeActive {
            typedText += text
            try await write(AndroidTVMessages.imeText(typedText, imeCounter: imeCounter, fieldCounter: fieldCounter))
            return
        }
        for character in text {
            guard let code = AndroidTVKeyMap.code(for: character) else { continue }
            try await write(AndroidTVMessages.key(code, direction: .short))
        }
    }

    public func launchApp(_ id: String) async throws {
        try await write(AndroidTVMessages.appLink(id))
    }

    public func listApps() async throws -> [TVApp] {
        AndroidTVAppLinks.common
    }

    // MARK: Pairing

    /// Opens the pairing port and runs the handshake up to the point where the TV shows a code.
    public func startPairing() async throws {
        teardown()
        closePairing()
        broadcaster.update(.pairing)
        do {
            let identity = try ClientIdentity.shared()
            let channel = TLSChannel(host: device.host, port: Self.pairingPort, identity: identity, pinnedCertificateSHA256: nil)
            try await channel.open()
            pairingChannel = channel
            try await exchange(AndroidTVMessages.pairingRequest(clientName: clientName), expecting: \.hasPairingRequestAck)
            try await exchange(AndroidTVMessages.options(), expecting: \.hasOptions)
            try await exchange(AndroidTVMessages.configuration(), expecting: \.hasConfigurationAck)
        } catch {
            closePairing()
            let driverError = DriverError(error)
            broadcaster.update(.error(driverError))
            throw driverError
        }
    }

    /// Checks the code locally first, so a typo doesn't burn the TV's pairing session.
    public func pair(code: String?) async throws -> PairingCredentials {
        guard let code else { throw DriverError.pairingCodeMismatch }
        if pairingChannel == nil { try await startPairing() }
        guard let channel = pairingChannel, let serverDER = channel.peerCertificateDER else {
            throw DriverError.pairingTimedOut
        }
        let identity = try ClientIdentity.shared()
        let secret = try PairingSecret.compute(
            client: identity.publicNumbers,
            server: try RSAPublicNumbers(certificateDER: Array(serverDER)),
            code: code.uppercased()
        )
        do {
            try await exchange(AndroidTVMessages.secret(secret), expecting: \.hasSecretAck)
        } catch {
            closePairing()
            let driverError = DriverError(error)
            broadcaster.update(.error(driverError))
            throw driverError
        }
        closePairing()
        credentials = PairingCredentials(platform: .androidTV)
        try await connect()
        return credentials ?? PairingCredentials(platform: .androidTV)
    }

    private func exchange(
        _ message: Polo_Wire_Protobuf_OuterMessage,
        expecting field: KeyPath<Polo_Wire_Protobuf_OuterMessage, Bool>
    ) async throws {
        guard let channel = pairingChannel else { throw DriverError.pairingTimedOut }
        try await channel.send(try AndroidTVMessages.framed(message))

        let timeout = Task {
            try? await Task.sleep(for: AndroidTVDriver.exchangeTimeout)
            if !Task.isCancelled { channel.close() }
        }
        defer { timeout.cancel() }
        guard let frame = try await channel.receive() else { throw DriverError.pairingTimedOut }

        let reply = try Polo_Wire_Protobuf_OuterMessage(serializedBytes: frame)
        switch reply.status {
        case .ok: break
        case .badSecret: throw DriverError.pairingCodeMismatch
        default: throw DriverError.pairingRejected
        }
        guard reply[keyPath: field] else {
            throw DriverError.protocolError("Unexpected pairing reply")
        }
    }

    private func closePairing() {
        pairingChannel?.close()
        pairingChannel = nil
    }
}
