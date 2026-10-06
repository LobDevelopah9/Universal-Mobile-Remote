import Foundation
import RemoteCore

public enum DriverFactory {
    /// Returns nil for platforms whose driver isn't in this build yet.
    public static func make(for device: DeviceDescriptor, credentials: PairingCredentials?) -> (any TVDriver)? {
        switch device.platform {
        case .roku:
            RokuDriver(device: device)
        case .androidTV:
            AndroidTVDriver(device: device, credentials: credentials)
        case .demo:
            MockTVDriver(device: device)
        case .samsung, .lg, .sony, .vizio, .fireTV, .appleTV:
            nil
        }
    }
}
