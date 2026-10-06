import CryptoKit
import Foundation
import Network
import RemoteCore
import Security

/// A mutually-authenticated TLS connection that delivers varint-framed messages.
///
/// TVs present a self-signed certificate, so system trust can't validate it.
/// During pairing it's accepted and recorded (trust on first use). After that,
/// connections only succeed if the TV presents the same certificate.
///
/// Frames are read with `receive()`, which supports exactly one consumer.
final class TLSChannel: @unchecked Sendable {
    private struct Inbox {
        var frames: [Data] = []
        var waiter: CheckedContinuation<Data?, any Error>?
        var isFinished = false
        var failure: (any Error)?
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let peerCertificate: Locked<Data?>
    private let framer = Locked(VarintFramer())
    private let inbox = Locked(Inbox())
    private let openContinuation = Locked<CheckedContinuation<Void, any Error>?>(nil)

    init(host: String, port: Int, identity: ClientIdentity, pinnedCertificateSHA256: String?) {
        let queue = DispatchQueue(label: "remote.tls.\(host):\(port)")
        let peer = Locked<Data?>(nil)
        self.queue = queue
        peerCertificate = peer

        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(security, secIdentity)
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let chain = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]) ?? []
            let leaf = chain.first.map { SecCertificateCopyData($0) as Data }
            peer.withLock { $0 = leaf }
            guard let pinnedCertificateSHA256 else {
                complete(leaf != nil)
                return
            }
            complete(leaf.map(TLSChannel.fingerprint) == pinnedCertificateSHA256)
        }, queue)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.cellular]
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(clamping: port)),
            using: parameters
        )
    }

    deinit {
        connection.cancel()
    }

    /// The TV's certificate (DER), available once the TLS handshake has run.
    var peerCertificateDER: Data? { peerCertificate.withLock { $0 } }

    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    func open(timeout: TimeInterval = 6) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            openContinuation.withLock { $0 = continuation }
            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finishOpen(.failure(DriverError.timeout))
            }
        }
        receiveNext()
    }

    /// The next complete message, or nil once the connection closed cleanly.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            let result = inbox.withLock { box -> Result<Data?, any Error>? in
                if !box.frames.isEmpty { return .success(box.frames.removeFirst()) }
                if box.isFinished {
                    if let failure = box.failure { return .failure(failure) }
                    return .success(nil)
                }
                box.waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DriverError(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        finish(nil)
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            finishOpen(.success(()))
        case .waiting(let error), .failed(let error):
            // `.waiting` means the TV refused or isn't there; fail fast instead of waiting.
            let driverError = DriverError(error)
            finishOpen(.failure(driverError))
            finish(driverError)
            connection.cancel()
        case .cancelled:
            finishOpen(.failure(DriverError.connectionLost))
            finish(nil)
        default:
            break
        }
    }

    private func finishOpen(_ result: Result<Void, any Error>) {
        let pending = openContinuation.withLock { value -> CheckedContinuation<Void, any Error>? in
            defer { value = nil }
            return value
        }
        pending?.resume(with: result)
    }

    private func deliver(_ frame: Data) {
        let waiter = inbox.withLock { box -> CheckedContinuation<Data?, any Error>? in
            guard !box.isFinished else { return nil }
            if let waiter = box.waiter {
                box.waiter = nil
                return waiter
            }
            box.frames.append(frame)
            return nil
        }
        waiter?.resume(returning: frame)
    }

    /// Ends the inbox. The first reason wins; later calls are ignored.
    private func finish(_ error: (any Error)?) {
        let waiter = inbox.withLock { box -> CheckedContinuation<Data?, any Error>? in
            guard !box.isFinished else { return nil }
            box.isFinished = true
            box.failure = error
            defer { box.waiter = nil }
            return box.waiter
        }
        if let error {
            waiter?.resume(throwing: error)
        } else {
            waiter?.resume(returning: nil)
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let frames = try framer.withLock { try $0.append(data) }
                    for frame in frames { deliver(frame) }
                } catch {
                    finish(error)
                    connection.cancel()
                    return
                }
            }
            if let error {
                finish(DriverError(error))
                return
            }
            if isComplete {
                finish(DriverError.connectionLost)
                return
            }
            receiveNext()
        }
    }
}
