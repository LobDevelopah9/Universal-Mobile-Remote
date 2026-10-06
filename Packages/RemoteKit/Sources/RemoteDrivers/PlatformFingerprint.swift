import Foundation
import RemoteCore

/// Works out which platform answers on a host, from its open ports and a quick
/// protocol-level check where one exists.
public enum PlatformFingerprint {
    /// Ports worth probing during a subnet sweep, and the platform each suggests.
    public static let probePorts: [Int: TVPlatform] = [
        RokuDriver.defaultPort: .roku,
        AndroidTVDriver.remotePort: .androidTV,
    ]

    public static func identify(host: String, openPorts: Set<Int>) async -> [DeviceDescriptor] {
        var found: [DeviceDescriptor] = []
        if openPorts.contains(RokuDriver.defaultPort), let roku = await roku(host: host) {
            found.append(roku)
        }
        if openPorts.contains(AndroidTVDriver.remotePort) {
            found.append(DeviceDescriptor(
                name: "Android TV (\(host))",
                platform: .androidTV,
                host: host,
                port: AndroidTVDriver.remotePort
            ))
        }
        return found
    }

    /// Confirms a Roku by reading `/query/device-info`, which also gives its name, serial and MAC.
    public static func roku(host: String, port: Int = RokuDriver.defaultPort) async -> DeviceDescriptor? {
        let client = ECPClient(host: host, port: port, timeout: 1.5)
        guard let info = try? await client.deviceInfo() else { return nil }
        return info.descriptor(host: host, port: port)
    }
}
