import Foundation

/// A logical remote button. Drivers map these to their protocol's key codes and
/// report the ones they can't send through `TVCapabilities`.
public enum RemoteKey: String, Codable, Sendable, CaseIterable, Hashable {
    case up, down, left, right, select
    case back, home, menu
    case playPause, rewind, fastForward, next, previous
    case volumeUp, volumeDown, mute
    case power, powerOn, powerOff
    case channelUp, channelDown
    case info, search, input
    case backspace, enter

    public var accessibilityLabel: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .select: "Select"
        case .back: "Back"
        case .home: "Home"
        case .menu: "Menu"
        case .playPause: "Play or pause"
        case .rewind: "Rewind"
        case .fastForward: "Fast forward"
        case .next: "Next"
        case .previous: "Previous"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        case .power: "Power"
        case .powerOn: "Power on"
        case .powerOff: "Power off"
        case .channelUp: "Channel up"
        case .channelDown: "Channel down"
        case .info: "Info"
        case .search: "Search"
        case .input: "Input"
        case .backspace: "Delete"
        case .enter: "Enter"
        }
    }

    public var isDirectional: Bool {
        switch self {
        case .up, .down, .left, .right: true
        default: false
        }
    }
}

/// How a key is being pressed. `.down`/`.up` are only sent when the driver
/// reports `.keyHold`; otherwise the UI repeats `.press`.
public enum KeyAction: Sendable, Hashable {
    case press
    case down
    case up
}

/// What a connected TV can do. The UI hides anything not in this set.
public struct TVCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let dpad = TVCapabilities(rawValue: 1 << 0)
    /// Native touch-surface events. Without it the touchpad is translated into D-pad keys.
    public static let touchpad = TVCapabilities(rawValue: 1 << 1)
    public static let keyboard = TVCapabilities(rawValue: 1 << 2)
    public static let volume = TVCapabilities(rawValue: 1 << 3)
    public static let mute = TVCapabilities(rawValue: 1 << 4)
    public static let power = TVCapabilities(rawValue: 1 << 5)
    public static let apps = TVCapabilities(rawValue: 1 << 6)
    public static let appIcons = TVCapabilities(rawValue: 1 << 7)
    public static let nowPlaying = TVCapabilities(rawValue: 1 << 8)
    /// Real key-down / key-up, so holding a button is a native long press.
    public static let keyHold = TVCapabilities(rawValue: 1 << 9)
    public static let mediaControls = TVCapabilities(rawValue: 1 << 10)
    public static let channels = TVCapabilities(rawValue: 1 << 11)
    public static let appList = TVCapabilities(rawValue: 1 << 12)

    public static let basic: TVCapabilities = [.dpad]
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case pairing
    case connected
    case error(DriverError)

    public var isConnected: Bool { self == .connected }
}

public struct TVApp: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var iconURL: URL?

    public init(id: String, name: String, iconURL: URL? = nil) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
    }
}

/// Whatever a platform needs to reconnect without pairing again. Stored in Keychain.
public struct PairingCredentials: Codable, Sendable, Equatable {
    public var platform: TVPlatform
    /// A session token or client key (Samsung, LG, Sony, Vizio).
    public var token: String?
    /// Extra platform-specific values, e.g. a pinned server-certificate fingerprint.
    public var values: [String: String]

    public init(platform: TVPlatform, token: String? = nil, values: [String: String] = [:]) {
        self.platform = platform
        self.token = token
        self.values = values
    }

    public static func none(_ platform: TVPlatform) -> PairingCredentials {
        PairingCredentials(platform: platform)
    }
}

/// Everything needed to reach one TV. Produced by discovery and stored for saved devices.
public struct DeviceDescriptor: Codable, Sendable, Hashable, Identifiable {
    /// Stable identifier, `<platform>/<kind>/<value>`, where kind is `serial`, `mac` or `ip`.
    public var id: String
    public var name: String
    public var platform: TVPlatform
    public var host: String
    public var port: Int
    public var mac: String?
    public var model: String?

    public init(
        id: String? = nil,
        name: String,
        platform: TVPlatform,
        host: String,
        port: Int,
        mac: String? = nil,
        model: String? = nil
    ) {
        let normalizedMAC = mac.flatMap(DeviceDescriptor.normalizeMAC)
        self.id = id ?? DeviceDescriptor.makeID(platform: platform, mac: normalizedMAC, host: host)
        self.name = name
        self.platform = platform
        self.host = host
        self.port = port
        self.mac = normalizedMAC
        self.model = model
    }

    public static func makeID(platform: TVPlatform, serial: String) -> String {
        "\(platform.rawValue)/serial/\(serial.lowercased())"
    }

    public static func makeID(platform: TVPlatform, mac: String?, host: String) -> String {
        if let mac { return "\(platform.rawValue)/mac/\(mac)" }
        return "\(platform.rawValue)/ip/\(host)"
    }

    /// True when the ID only encodes an IP address and so may change with DHCP.
    public var hasAddressBasedID: Bool { id.hasPrefix("\(platform.rawValue)/ip/") }

    /// Lowercase, colon-separated, or nil if it isn't a usable MAC.
    public static func normalizeMAC(_ raw: String) -> String? {
        let hex = raw.lowercased().filter(\.isHexDigit)
        guard hex.count == 12, hex != "000000000000" else { return nil }
        var parts: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]))
            index = next
        }
        return parts.joined(separator: ":")
    }
}
