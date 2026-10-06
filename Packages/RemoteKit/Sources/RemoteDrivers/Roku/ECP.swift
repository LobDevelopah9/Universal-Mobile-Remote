import Foundation
import RemoteCore

/// Roku External Control Protocol key names.
enum ECPKeyMap {
    static func name(for key: RemoteKey) -> String? {
        switch key {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .select: "Select"
        case .back: "Back"
        case .home: "Home"
        case .menu, .info: "Info"
        case .playPause: "Play"
        case .rewind: "Rev"
        case .fastForward: "Fwd"
        case .previous: "InstantReplay"
        case .next: nil
        case .volumeUp: "VolumeUp"
        case .volumeDown: "VolumeDown"
        case .mute: "VolumeMute"
        case .power: "Power"
        case .powerOn: "PowerOn"
        case .powerOff: "PowerOff"
        case .channelUp: "ChannelUp"
        case .channelDown: "ChannelDown"
        case .search: "Search"
        case .input: "InputTuner"
        case .backspace: "Backspace"
        case .enter: "Enter"
        }
    }

    /// `Lit_<char>`, with the character percent-encoded as UTF-8.
    static func literal(_ character: Character) -> String {
        let encoded = String(character).addingPercentEncoding(withAllowedCharacters: .ecpUnreserved) ?? ""
        return "Lit_" + encoded
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters. Everything else gets percent-encoded in a path segment.
    static let ecpUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

/// The fields of `/query/device-info` the app uses.
struct RokuDeviceInfo: Sendable, Equatable {
    var serialNumber: String?
    var friendlyName: String?
    var modelName: String?
    var wifiMAC: String?
    var ethernetMAC: String?
    var isTV: Bool
    var powerMode: String?

    init(fields: [String: String]) {
        serialNumber = fields["serial-number"]
        friendlyName = fields["user-device-name"].nonEmpty
            ?? fields["friendly-device-name"].nonEmpty
            ?? fields["default-device-name"].nonEmpty
        modelName = fields["friendly-model-name"].nonEmpty ?? fields["model-name"].nonEmpty
        wifiMAC = fields["wifi-mac"].nonEmpty
        ethernetMAC = fields["ethernet-mac"].nonEmpty
        isTV = fields["is-tv"] == "true"
        powerMode = fields["power-mode"]
    }

    func descriptor(host: String, port: Int) -> DeviceDescriptor {
        let id = serialNumber.map { DeviceDescriptor.makeID(platform: .roku, serial: $0) }
        return DeviceDescriptor(
            id: id,
            name: friendlyName ?? modelName ?? "Roku (\(host))",
            platform: .roku,
            host: host,
            port: port,
            mac: [wifiMAC, ethernetMAC].compactMap { $0.flatMap(DeviceDescriptor.normalizeMAC) }.first,
            model: modelName
        )
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}

/// Parses the two ECP XML documents the app reads.
enum RokuXML {
    /// `<device-info>` has one flat level of child elements.
    static func deviceInfo(_ data: Data) throws -> RokuDeviceInfo {
        let collector = FlatElementCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse(), collector.root == "device-info" else {
            throw DriverError.protocolError("Unexpected device-info response")
        }
        return RokuDeviceInfo(fields: collector.fields)
    }

    /// `<apps><app id="12" type="appl" version="4.1">Netflix</app>…</apps>`
    static func apps(_ data: Data, iconBase: URL?) throws -> [TVApp] {
        let collector = AppCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { throw DriverError.protocolError("Unexpected app list") }
        return collector.apps
            // Channels ("appl") and, on Roku TVs, inputs ("tvin"); not the "menu" pseudo-app.
            .filter { $0.type == nil || $0.type == "appl" || $0.type == "tvin" }
            .map { app in
                TVApp(
                    id: app.id,
                    name: app.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    iconURL: iconBase?.appendingPathComponent("query/icon/\(app.id)")
                )
            }
    }

    private final class FlatElementCollector: NSObject, XMLParserDelegate {
        var root: String?
        var fields: [String: String] = [:]
        private var current: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if root == nil { root = name; return }
            current = name
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if current != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == current {
                fields[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                current = nil
            }
        }
    }

    private final class AppCollector: NSObject, XMLParserDelegate {
        struct RawApp { var id: String; var type: String?; var name: String }
        var apps: [RawApp] = []
        private var pending: RawApp?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == "app", let id = attributes["id"] else { return }
            pending = RawApp(id: id, type: attributes["type"], name: "")
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            pending?.name += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "app", let app = pending {
                apps.append(app)
                pending = nil
            }
        }
    }
}

/// HTTP client for one Roku's ECP endpoint (`http://<ip>:8060`).
struct ECPClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    init(host: String, port: Int = 8060, timeout: TimeInterval = 2) {
        baseURL = URL(string: "http://\(host):\(port)/")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func keypress(_ key: String) async throws { try await post("keypress/\(key)") }
    func keydown(_ key: String) async throws { try await post("keydown/\(key)") }
    func keyup(_ key: String) async throws { try await post("keyup/\(key)") }

    func launch(_ appID: String) async throws {
        let escaped = appID.addingPercentEncoding(withAllowedCharacters: .ecpUnreserved) ?? appID
        try await post("launch/\(escaped)")
    }

    func deviceInfo() async throws -> RokuDeviceInfo {
        try RokuXML.deviceInfo(try await get("query/device-info"))
    }

    func apps() async throws -> [TVApp] {
        try RokuXML.apps(try await get("query/apps"), iconBase: baseURL)
    }

    private func url(_ path: String) -> URL {
        // Built from a string so percent-escapes in `Lit_` keys are kept as-is.
        URL(string: baseURL.absoluteString + path)!
    }

    private func post(_ path: String) async throws {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.httpBody = Data()
        let (_, response) = try await perform(request)
        try check(response)
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await perform(URLRequest(url: url(path)))
        try check(response)
        return data
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw DriverError(error)
        }
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        // Roku answers 403 when "Control by mobile apps" is set to Limited or Disabled.
        case 401, 403: throw DriverError.rokuMobileControlDisabled
        case 404: throw DriverError.unsupported("that command")
        default: throw DriverError.tvError("HTTP \(http.statusCode)")
        }
    }
}
