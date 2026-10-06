import Foundation
import Network
import RemoteCore
import RemoteDrivers

/// SSDP M-SEARCH over UDP multicast. iOS only allows this with the
/// `com.apple.developer.networking.multicast` entitlement, so it's opt-in
/// (`ENABLE_MULTICAST=YES`). Without the entitlement the group fails to start and
/// this source quietly does nothing.
public struct SSDPSource: DiscoverySource {
    public static let searchTargets = ["roku:ecp"]

    public init() {}

    public func run(emit: @escaping @Sendable (DiscoveryEvent) async -> Void) async {
        guard let multicast = try? NWMulticastGroup(for: [.hostPort(host: "239.255.255.250", port: 1900)]) else { return }
        let group = NWConnectionGroup(with: multicast, using: .udp)
        let (responses, continuation) = AsyncStream.makeStream(of: String.self)

        group.setReceiveHandler(maximumMessageSize: 8192, rejectOversizedMessages: true) { _, content, _ in
            if let content, let text = String(data: content, encoding: .utf8) {
                continuation.yield(text)
            }
        }
        group.stateUpdateHandler = { state in
            switch state {
            case .ready:
                for target in SSDPSource.searchTargets {
                    group.send(content: SSDPSource.searchRequest(target: target)) { _ in }
                }
            case .failed, .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        group.start(queue: DispatchQueue(label: "remote.ssdp"))

        await withTaskCancellationHandler {
            var seen: Set<String> = []
            for await text in responses {
                guard let response = SSDPResponse(text), let host = response.location.host,
                      seen.insert(host).inserted
                else { continue }
                if response.isRoku, let device = await PlatformFingerprint.roku(host: host, port: response.location.port ?? RokuDriver.defaultPort) {
                    await emit(.found(device, source: .ssdp))
                }
            }
        } onCancel: {
            group.cancel()
            continuation.finish()
        }
    }

    static func searchRequest(target: String) -> Data {
        Data((
            "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 2\r\n" +
            "ST: \(target)\r\n\r\n"
        ).utf8)
    }
}

/// The parts of an SSDP response or NOTIFY that matter for fingerprinting.
public struct SSDPResponse: Sendable, Equatable {
    public var location: URL
    public var searchTarget: String?
    public var usn: String?
    public var server: String?

    public init?(_ text: String) {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard let rawLocation = headers["LOCATION"], let location = URL(string: rawLocation) else { return nil }
        self.location = location
        searchTarget = headers["ST"] ?? headers["NT"]
        usn = headers["USN"]
        server = headers["SERVER"]
    }

    public var isRoku: Bool {
        searchTarget?.lowercased() == "roku:ecp" || usn?.lowercased().contains("roku:ecp") == true
    }
}
