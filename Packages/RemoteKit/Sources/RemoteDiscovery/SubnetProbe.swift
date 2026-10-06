import Darwin
import Foundation
import Network
import RemoteCore

/// One local IPv4 interface, as host-order integers.
public struct IPv4Interface: Sendable, Equatable {
    public var name: String
    public var address: UInt32
    public var netmask: UInt32

    public init(name: String, address: UInt32, netmask: UInt32) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }

    public init?(name: String, address: String, netmask: String) {
        guard let address = IPv4Interface.parse(address), let netmask = IPv4Interface.parse(netmask) else { return nil }
        self.init(name: name, address: address, netmask: netmask)
    }

    public var addressString: String { IPv4Interface.format(address) }

    /// Every host address to sweep. Large subnets are limited to this device's own /24,
    /// so a /16 office network doesn't mean 65 000 probes.
    public var sweepHosts: [String] {
        let mask = max(netmask, 0xFFFF_FF00)
        let network = address & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast)
            .filter { $0 != address }
            .map(IPv4Interface.format)
    }

    static func parse(_ string: String) -> UInt32? {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }

    static func format(_ value: UInt32) -> String {
        "\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    /// Up, running, non-loopback IPv4 interfaces. Wi-Fi (`en0`) first.
    public static func current() -> [IPv4Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [IPv4Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            // Skip VPN tunnels and the like; TVs live on the physical LAN.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let address = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(IPv4Interface(name: name, address: address, netmask: netmask))
        }
        return result.sorted { ($0.name == "en0" ? 0 : 1) < ($1.name == "en0" ? 0 : 1) }
    }
}

/// Finds TVs without multicast: a parallel TCP connect sweep of known ports across the /24.
public struct SubnetProbe: DiscoverySource {
    public var concurrency: Int
    public var timeout: Duration

    public init(concurrency: Int = 64, timeout: Duration = .milliseconds(350)) {
        self.concurrency = concurrency
        self.timeout = timeout
    }

    public func run(emit: @escaping @Sendable (DiscoveryEvent) async -> Void) async {
        guard let interface = IPv4Interface.current().first else { return }
        let ports = Array(PlatformFingerprint.probePorts.keys).sorted()
        let targets = interface.sweepHosts.flatMap { host in ports.map { (host, $0) } }
        let timeout = timeout

        var open: [String: Set<Int>] = [:]
        await withTaskGroup(of: (String, Int, Bool).self) { group in
            // Sliding window: keep `concurrency` probes in flight.
            var next = 0
            while next < min(concurrency, targets.count) {
                let (host, port) = targets[next]
                group.addTask { (host, port, await SubnetProbe.isOpen(host: host, port: port, timeout: timeout)) }
                next += 1
            }
            while let (host, port, isOpen) = await group.next() {
                if isOpen { open[host, default: []].insert(port) }
                if next < targets.count {
                    let (host, port) = targets[next]
                    group.addTask { (host, port, await SubnetProbe.isOpen(host: host, port: port, timeout: timeout)) }
                    next += 1
                }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for (host, ports) in open {
                group.addTask {
                    for device in await PlatformFingerprint.identify(host: host, openPorts: ports) {
                        await emit(.found(device, source: .subnetProbe))
                    }
                }
            }
        }
    }

    /// Probes a single host on every known port. Used for manual IP entry.
    public static func identify(host: String, timeout: Duration = .seconds(1)) async -> [DeviceDescriptor] {
        var open: Set<Int> = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for port in PlatformFingerprint.probePorts.keys {
                group.addTask { (port, await isOpen(host: host, port: port, timeout: timeout)) }
            }
            for await (port, isOpen) in group where isOpen { open.insert(port) }
        }
        return await PlatformFingerprint.identify(host: host, openPorts: open)
    }

    /// True if a TCP handshake completes within `timeout`.
    public static func isOpen(host: String, port: Int, timeout: Duration) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)),
            using: parameters
        )
        return await connection.waitUntilReady(timeout: timeout) != nil
    }
}
