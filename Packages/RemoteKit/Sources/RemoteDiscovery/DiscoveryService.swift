import Foundation
import RemoteCore
import RemoteDrivers

public enum DiscoverySourceKind: String, Sendable {
    case bonjour, ssdp, subnetProbe, manual
}

public enum DiscoveryEvent: Sendable, Equatable {
    case found(DeviceDescriptor, source: DiscoverySourceKind)
    case localNetworkDenied
}

/// One way of finding TVs. `run` returns when the source is done or its task is cancelled.
public protocol DiscoverySource: Sendable {
    func run(emit: @escaping @Sendable (DiscoveryEvent) async -> Void) async
}

public struct DiscoverySnapshot: Sendable, Equatable {
    public var devices: [DeviceDescriptor]
    public var isScanning: Bool
    public var localNetworkDenied: Bool

    public static let empty = DiscoverySnapshot(devices: [], isScanning: false, localNetworkDenied: false)
}

/// Merges every source into one deduplicated, live device list.
public actor DiscoveryService {
    public static let scanDuration: Duration = .seconds(8)

    private let sources: [any DiscoverySource]
    private let broadcaster = StateBroadcaster(DiscoverySnapshot.empty)
    private var merger = DeviceMerger()
    private var runTask: Task<Void, Never>?
    private var scanTimer: Task<Void, Never>?

    public init(sources: [any DiscoverySource]) {
        self.sources = sources
    }

    /// Bonjour and the subnet sweep always; SSDP only with the multicast entitlement.
    public static func standard(multicastEnabled: Bool) -> DiscoveryService {
        var sources: [any DiscoverySource] = [BonjourSource(), SubnetProbe()]
        if multicastEnabled { sources.append(SSDPSource()) }
        return DiscoveryService(sources: sources)
    }

    public var snapshots: AsyncStream<DiscoverySnapshot> { broadcaster.stream() }

    public func start() {
        guard runTask == nil else { return }
        var snapshot = broadcaster.current
        snapshot.isScanning = true
        broadcaster.send(snapshot)

        let sources = sources
        runTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask {
                        await source.run { event in await self?.receive(event) }
                    }
                }
            }
        }
        scanTimer = Task { [weak self] in
            try? await Task.sleep(for: DiscoveryService.scanDuration)
            guard !Task.isCancelled else { return }
            await self?.finishScanning()
        }
    }

    public func stop() {
        runTask?.cancel()
        scanTimer?.cancel()
        runTask = nil
        scanTimer = nil
        var snapshot = broadcaster.current
        snapshot.isScanning = false
        broadcaster.update(snapshot)
    }

    /// Forget everything found so far and scan again (pull to refresh, or after
    /// Local Network permission was granted).
    public func rescan() {
        stop()
        merger = DeviceMerger()
        broadcaster.send(.empty)
        start()
    }

    /// Manual IP entry: probe one host and merge what it turns out to be.
    public func probe(host: String) async -> [DeviceDescriptor] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = await SubnetProbe.identify(host: trimmed)
        for device in found { receive(.found(device, source: .manual)) }
        return found
    }

    private func receive(_ event: DiscoveryEvent) {
        var snapshot = broadcaster.current
        switch event {
        case .found(let device, _):
            guard merger.insert(device) else { return }
            snapshot.devices = merger.devices
            snapshot.localNetworkDenied = false
        case .localNetworkDenied:
            snapshot.localNetworkDenied = true
        }
        broadcaster.update(snapshot)
    }

    private func finishScanning() {
        var snapshot = broadcaster.current
        snapshot.isScanning = false
        broadcaster.update(snapshot)
    }
}

/// Deduplicates devices seen by several sources. Two sightings are the same TV if
/// they share an ID, a MAC, or a host on the same platform. Merging keeps the most
/// stable ID and the most descriptive name.
public struct DeviceMerger: Sendable {
    public private(set) var devices: [DeviceDescriptor] = []

    public init() {}

    /// Returns true if the list changed.
    @discardableResult
    public mutating func insert(_ device: DeviceDescriptor) -> Bool {
        guard let index = devices.firstIndex(where: { Self.isSame($0, device) }) else {
            devices.append(device)
            return true
        }
        let merged = Self.merge(devices[index], device)
        guard merged != devices[index] else { return false }
        devices[index] = merged
        return true
    }

    static func isSame(_ a: DeviceDescriptor, _ b: DeviceDescriptor) -> Bool {
        if a.id == b.id { return true }
        guard a.platform == b.platform else { return false }
        if let macA = a.mac, let macB = b.mac { return macA == macB }
        return a.host == b.host
    }

    static func merge(_ old: DeviceDescriptor, _ new: DeviceDescriptor) -> DeviceDescriptor {
        var merged = new
        if new.hasAddressBasedID && !old.hasAddressBasedID { merged.id = old.id }
        if isPlaceholderName(new) && !isPlaceholderName(old) { merged.name = old.name }
        merged.mac = new.mac ?? old.mac
        merged.model = new.model ?? old.model
        if merged.hasAddressBasedID, let mac = merged.mac {
            merged.id = DeviceDescriptor.makeID(platform: merged.platform, mac: mac, host: merged.host)
        }
        return merged
    }

    /// Names like "Android TV (192.168.1.20)" that only stand in until a real one shows up.
    static func isPlaceholderName(_ device: DeviceDescriptor) -> Bool {
        device.name.hasSuffix("(\(device.host))")
    }
}
