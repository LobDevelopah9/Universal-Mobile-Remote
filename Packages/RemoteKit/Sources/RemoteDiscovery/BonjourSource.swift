import Foundation
import Network
import RemoteCore
import RemoteDrivers

/// Browses Bonjour service types that identify a TV platform.
public struct BonjourSource: DiscoverySource {
    /// Must match `NSBonjourServices` in Info.plist, or iOS silently returns nothing.
    public static let serviceTypes: [String: TVPlatform] = [
        "_androidtvremote2._tcp": .androidTV,
    ]

    public init() {}

    public func run(emit: @escaping @Sendable (DiscoveryEvent) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for (type, platform) in Self.serviceTypes {
                group.addTask { await Self.browse(type: type, platform: platform, emit: emit) }
            }
        }
    }

    private struct Sighting: Sendable {
        var name: String
        var endpoint: NWEndpoint
        var mac: String?
    }

    private static func browse(type: String, platform: TVPlatform, emit: @escaping @Sendable (DiscoveryEvent) async -> Void) async {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
        let (sightings, continuation) = AsyncStream.makeStream(of: Sighting.self)

        browser.browseResultsChangedHandler = { _, changes in
            for change in changes {
                guard case .added(let result) = change, case .service(let name, _, _, _) = result.endpoint else { continue }
                var mac: String?
                if case .bonjour(let txt) = result.metadata { mac = txt["bt"] }
                continuation.yield(Sighting(name: name, endpoint: result.endpoint, mac: mac))
            }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .waiting(let error), .failed(let error):
                if DriverError(error) == .localNetworkDenied {
                    Task { await emit(.localNetworkDenied) }
                }
                if case .failed = state { continuation.finish() }
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        browser.start(queue: DispatchQueue(label: "remote.bonjour.\(type)"))

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for await sighting in sightings {
                    group.addTask {
                        guard let address = await resolve(sighting.endpoint) else { return }
                        let device = DeviceDescriptor(
                            name: sighting.name,
                            platform: platform,
                            host: address.host,
                            port: address.port,
                            mac: sighting.mac
                        )
                        await emit(.found(device, source: .bonjour))
                    }
                }
            }
        } onCancel: {
            browser.cancel()
            continuation.finish()
        }
    }

    /// Resolves a Bonjour service to an IPv4 address by briefly connecting to it.
    static func resolve(_ endpoint: NWEndpoint) async -> (host: String, port: Int)? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        guard let path = await connection.waitUntilReady(timeout: .seconds(3)),
              case .hostPort(let host, let port) = path.remoteEndpoint
        else { return nil }
        return (host.addressString, Int(port.rawValue))
    }
}

extension NWEndpoint.Host {
    /// Dotted IPv4, bare IPv6 (no zone), or the hostname.
    var addressString: String {
        switch self {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .name(let name, _): name
        @unknown default: "\(self)"
        }
    }
}

extension NWConnection {
    /// Starts the connection and returns its path once ready, or nil on failure or
    /// timeout. The connection is always cancelled before returning.
    func waitUntilReady(timeout: Duration) async -> NWPath? {
        let resumed = Locked(false)
        let queue = DispatchQueue(label: "remote.connect")
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWPath?, Never>) in
            let finish: @Sendable (NWPath?) -> Void = { path in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                self.cancel()
                continuation.resume(returning: path)
            }
            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: finish(self?.currentPath)
                case .failed, .waiting, .cancelled: finish(nil)
                default: break
                }
            }
            start(queue: queue)
            let nanos = timeout.components.seconds * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) { finish(nil) }
        }
    }
}
