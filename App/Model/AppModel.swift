import Observation
import RemoteCore
import RemoteDiscovery
import RemoteDrivers
import RemoteStorage
import SwiftData
import SwiftUI

/// App-wide state: saved devices, discovery, the active remote session and routing.
@MainActor
@Observable
final class AppModel {
    let store: DeviceStore
    let discovery: DiscoveryService

    private(set) var snapshot = DiscoverySnapshot.empty
    private(set) var session: RemoteViewModel?
    var pairingTarget: DeviceDescriptor?
    var isAddingTV = false

    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var discoveryUsers = 0

    init(container: ModelContainer, discovery: DiscoveryService? = nil) {
        store = DeviceStore(container: container)
        self.discovery = discovery ?? .standard(multicastEnabled: AppSettings.multicastEnabled)
        observeDiscovery()
        Haptics.prepare()
        if let last = store.lastUsed {
            activate(last)
        }
    }

    // MARK: Discovery

    /// Devices to offer in "Find your TV": what's on the network, plus the Demo TV in debug builds.
    var discoveredDevices: [DeviceDescriptor] {
        snapshot.devices.filter { $0.platform.isSupported }
    }

    var unsupportedDevices: [DeviceDescriptor] {
        snapshot.devices.filter { !$0.platform.isSupported }
    }

    func isSaved(_ device: DeviceDescriptor) -> Bool { store.contains(device.id) }

    /// Reference-counted so nested "Find your TV" screens don't stop each other's scan.
    func beginDiscovery() {
        discoveryUsers += 1
        guard discoveryUsers == 1 else { return }
        Task { await discovery.start() }
    }

    func endDiscovery() {
        discoveryUsers = max(0, discoveryUsers - 1)
        guard discoveryUsers == 0 else { return }
        Task { await discovery.stop() }
    }

    func rescan() async {
        await discovery.rescan()
    }

    func probe(host: String) async -> [DeviceDescriptor] {
        await discovery.probe(host: host)
    }

    private func observeDiscovery() {
        discoveryTask = Task { [weak self, discovery] in
            for await snapshot in await discovery.snapshots {
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: DiscoverySnapshot) {
        self.snapshot = snapshot
        // A saved TV that DHCP moved: follow it so reconnects keep working.
        for device in snapshot.devices where store.contains(device.id) {
            store.updateAddress(device.id, host: device.host, port: device.port)
        }
    }

    // MARK: Sessions

    /// Tapping a TV in a list: saved ones connect straight away, new ones pair first.
    func select(_ device: DeviceDescriptor) {
        isAddingTV = false
        if store.contains(device.id), device.platform.pairingStyle == .automatic || store.credentials.credentials(for: device.id) != nil {
            activate(device)
        } else {
            pairingTarget = device
        }
    }

    func repair(_ device: DeviceDescriptor) {
        pairingTarget = device
    }

    /// Connects to a saved device and makes it the active remote.
    func activate(_ device: DeviceDescriptor) {
        guard session?.device.id != device.id else { return }
        let credentials = store.credentials.credentials(for: device.id)
        guard let driver = DriverFactory.make(for: device, credentials: credentials) else { return }
        replaceSession(with: RemoteViewModel(device: device, driver: driver, alreadyConnected: false))
        store.markUsed(device.id)
    }

    /// Called by the pairing flow with a driver that is already connected.
    func completePairing(device: DeviceDescriptor, driver: any TVDriver, credentials: PairingCredentials) {
        do {
            try store.save(device, credentials: credentials)
        } catch {
            // Still usable this session; it just won't be remembered.
        }
        pairingTarget = nil
        replaceSession(with: RemoteViewModel(device: device, driver: driver, alreadyConnected: true))
    }

    func forget(_ id: String) {
        if session?.device.id == id {
            session?.close()
            session = nil
        }
        store.forget(id)
        if session == nil, let next = store.lastUsed {
            activate(next)
        }
    }

    func rename(_ id: String, to name: String) {
        store.rename(id, to: name)
        session?.deviceRenamed(store.devices.first { $0.id == id })
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: session?.appBecameActive()
        case .background: session?.appEnteredBackground()
        default: break
        }
    }

    private func replaceSession(with newSession: RemoteViewModel) {
        session?.close()
        session = newSession
        newSession.start()
    }
}
