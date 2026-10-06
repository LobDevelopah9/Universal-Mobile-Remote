import Observation
import RemoteCore
import SwiftUI

/// One TV's remote session: maps gestures to commands and mirrors connection state.
///
/// Every input path is synchronous and fire-and-forget: haptic, then enqueue.
/// The UI never waits on the network.
@MainActor
@Observable
final class RemoteViewModel {
    private(set) var device: DeviceDescriptor
    let driver: any TVDriver

    private(set) var state: ConnectionState = .connecting
    private(set) var capabilities: TVCapabilities = .basic
    private(set) var apps: [TVApp] = []
    private(set) var isLoadingApps = false
    private(set) var appsError: DriverError?
    /// A problem the user has to act on. Transient drops show as "Reconnecting…" instead.
    var alert: DriverError?

    @ObservationIgnored private let alreadyConnected: Bool
    @ObservationIgnored private var queue: CommandQueue?
    @ObservationIgnored private var keepAlive: KeepAlive?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var touchpad = TouchpadInterpreter()
    @ObservationIgnored private var lastTouchpadTranslation: CGSize = .zero
    @ObservationIgnored private var lastTypedText = ""

    init(device: DeviceDescriptor, driver: any TVDriver, alreadyConnected: Bool) {
        self.device = device
        self.driver = driver
        self.alreadyConnected = alreadyConnected
        state = alreadyConnected ? .connected : .connecting
    }

    var isReconnecting: Bool {
        switch state {
        case .connecting: true
        case .error(let error): error.isTransient
        case .disconnected: true
        default: false
        }
    }

    // MARK: Lifecycle

    func start() {
        queue = CommandQueue(driver: driver) { [weak self] error in
            guard let self else { return }
            Task { @MainActor in self.commandFailed(error) }
        }
        let driver = driver
        stateTask = Task { [weak self] in
            for await state in await driver.state {
                await self?.apply(state)
            }
        }
        let keepAlive = KeepAlive(driver: driver)
        self.keepAlive = keepAlive
        let alreadyConnected = alreadyConnected
        Task {
            if !alreadyConnected {
                try? await driver.connect()
            }
            await keepAlive.start()
        }
    }

    func close() {
        stateTask?.cancel()
        queue?.close()
        let keepAlive = keepAlive
        let driver = driver
        Task {
            await keepAlive?.stop()
            await driver.disconnect()
        }
    }

    func appBecameActive() {
        let keepAlive = keepAlive
        Task { await keepAlive?.reconnectNow() }
    }

    func appEnteredBackground() {
        // Nothing to tear down: TVs drop idle connections themselves, and KeepAlive
        // reconnects as soon as the app is active again.
    }

    func reconnect() {
        alert = nil
        let driver = driver
        Task { try? await driver.connect() }
    }

    func deviceRenamed(_ updated: DeviceDescriptor?) {
        if let updated, updated.id == device.id { device = updated }
    }

    private func apply(_ newState: ConnectionState) async {
        state = newState
        switch newState {
        case .connected:
            alert = nil
            let previous = capabilities
            capabilities = await driver.capabilities
            if apps.isEmpty || previous != capabilities {
                await loadApps()
            }
        case .error(let error) where !error.isTransient:
            alert = error
            Haptics.error()
        default:
            break
        }
    }

    private func commandFailed(_ error: DriverError) {
        // Single dropped presses on a flaky link aren't worth interrupting for;
        // KeepAlive is already reconnecting. Anything the user must fix is shown.
        guard !error.isTransient else { return }
        if case .unsupported = error { return }
        alert = error
        Haptics.error()
    }

    // MARK: Buttons

    func press(_ key: RemoteKey) {
        Haptics.press()
        queue?.enqueue(.key(key, .press))
    }

    /// Auto-repeat tick for a held button. No haptic per repeat, or it buzzes.
    func repeatPress(_ key: RemoteKey) {
        queue?.enqueue(.key(key, .press))
    }

    func holdBegan(_ key: RemoteKey) {
        Haptics.hold()
        queue?.enqueue(.key(key, .down))
    }

    func holdEnded(_ key: RemoteKey) {
        queue?.enqueue(.key(key, .up))
    }

    var supportsKeyHold: Bool { capabilities.contains(.keyHold) }

    // MARK: Touchpad

    func touchpadBegan() {
        touchpad = TouchpadInterpreter(sensitivity: AppSettings.touchpadSensitivity)
        touchpad.begin()
        lastTouchpadTranslation = .zero
    }

    func touchpadMoved(_ translation: CGSize) {
        if capabilities.contains(.touchpad) {
            let dx = translation.width - lastTouchpadTranslation.width
            let dy = translation.height - lastTouchpadTranslation.height
            lastTouchpadTranslation = translation
            queue?.enqueue(.swipe(dx: dx, dy: dy))
            return
        }
        for key in touchpad.update(translationX: translation.width, translationY: translation.height) {
            Haptics.tick()
            queue?.enqueue(.key(key, .press))
        }
    }

    func touchpadEnded(_ translation: CGSize, duration: TimeInterval) {
        if TouchpadInterpreter.isTap(translationX: translation.width, translationY: translation.height, duration: duration) {
            press(.select)
        }
    }

    // MARK: Keyboard

    func beginTyping() {
        lastTypedText = ""
    }

    /// Streams the difference since the last call: backspaces, then inserted text.
    func typingChanged(to text: String) {
        let edit = TextDiff.edit(from: lastTypedText, to: text)
        lastTypedText = text
        guard !edit.isEmpty else { return }
        for _ in 0..<edit.deleteCount {
            queue?.enqueue(.key(.backspace, .press))
        }
        if !edit.insertion.isEmpty {
            queue?.enqueue(.text(edit.insertion))
        }
    }

    func submitTyping() {
        press(.enter)
    }

    // MARK: Apps

    func loadApps() async {
        guard capabilities.contains(.apps) else {
            apps = []
            return
        }
        isLoadingApps = true
        defer { isLoadingApps = false }
        do {
            apps = try await driver.listApps()
            appsError = nil
        } catch {
            appsError = DriverError(error)
        }
    }

    func launch(_ app: TVApp) {
        Haptics.press()
        queue?.enqueue(.launch(appID: app.id))
    }
}
