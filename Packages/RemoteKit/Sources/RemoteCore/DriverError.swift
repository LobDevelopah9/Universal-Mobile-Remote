import Foundation
import Network

/// Every failure a driver can surface. Each case says what happened and what to do about it.
public enum DriverError: Error, Sendable, Equatable, Hashable {
    case notOnSameNetwork
    case localNetworkDenied
    case unreachable
    case refused
    case timeout
    case connectionLost
    case pairingRequired
    case pairingRejected
    case pairingCodeMismatch
    case pairingTimedOut
    case rokuMobileControlDisabled
    case unsupported(String)
    case tvError(String)
    case protocolError(String)

    public var userMessage: String {
        switch self {
        case .notOnSameNetwork:
            "Your phone and TV must be on the same Wi-Fi."
        case .localNetworkDenied:
            "Remote needs Local Network access to find and control your TV."
        case .unreachable:
            "Can't reach the TV. Make sure it's turned on and connected to Wi-Fi."
        case .refused:
            "The TV refused the connection."
        case .timeout:
            "The TV took too long to respond."
        case .connectionLost:
            "Lost the connection to the TV. Reconnecting…"
        case .pairingRequired:
            "This TV needs to be paired again."
        case .pairingRejected:
            "Pairing was declined on the TV."
        case .pairingCodeMismatch:
            "That code doesn't match the one on your TV."
        case .pairingTimedOut:
            "Pairing timed out."
        case .rokuMobileControlDisabled:
            "Your Roku is blocking control from phone apps."
        case .unsupported(let what):
            "This TV doesn't support \(what)."
        case .tvError(let message):
            "The TV reported an error: \(message)"
        case .protocolError:
            "The TV sent something unexpected."
        }
    }

    /// The concrete next step for the user, if there is one.
    public var recoverySuggestion: String? {
        switch self {
        case .notOnSameNetwork:
            "Connect your phone to the same Wi-Fi network as the TV, then try again."
        case .localNetworkDenied:
            "Open Settings → Privacy & Security → Local Network and turn on Remote."
        case .unreachable, .timeout:
            "Check that the TV is on and on the same Wi-Fi as your phone."
        case .refused:
            "Turn the TV off and on again. If it keeps happening, re-pair it from Settings."
        case .connectionLost:
            nil
        case .pairingRequired:
            "Go to Settings, pick this TV, and tap Re-pair."
        case .pairingRejected:
            "Try again and accept the prompt on your TV."
        case .pairingCodeMismatch:
            "Check the code on the TV screen and type it again."
        case .pairingTimedOut:
            "Start pairing again and enter the code while it's still on screen."
        case .rokuMobileControlDisabled:
            "On the Roku, go to Settings → System → Advanced system settings → Control by mobile apps, and set Network access to Default or Permissive."
        case .unsupported, .protocolError:
            nil
        case .tvError:
            "Restart the TV and try again."
        }
    }

    /// Whether automatic reconnection is worth trying.
    public var isTransient: Bool {
        switch self {
        case .connectionLost, .timeout, .unreachable, .refused, .notOnSameNetwork: true
        default: false
        }
    }

    /// Maps any thrown error to a `DriverError`.
    public init(_ error: any Error) {
        if let driverError = error as? DriverError {
            self = driverError
        } else if let nwError = error as? NWError {
            self = DriverError(nwError)
        } else if let urlError = error as? URLError {
            self = DriverError(urlError)
        } else if error is CancellationError {
            self = .connectionLost
        } else {
            self = .protocolError(String(describing: error))
        }
    }

    public init(_ error: NWError) {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: self = .refused
            case .ETIMEDOUT: self = .timeout
            case .EHOSTUNREACH, .EHOSTDOWN: self = .unreachable
            case .ENETUNREACH, .ENETDOWN: self = .notOnSameNetwork
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ECONNABORTED: self = .connectionLost
            default: self = .protocolError("POSIX \(code.rawValue)")
            }
        case .dns(let code):
            // kDNSServiceErr_PolicyDenied: the user declined Local Network access.
            self = code == -65570 ? .localNetworkDenied : .unreachable
        case .tls:
            // A TLS failure on a paired device almost always means the TV forgot us.
            self = .pairingRequired
        default:
            self = .protocolError(error.debugDescription)
        }
    }

    public init(_ error: URLError) {
        switch error.code {
        case .timedOut: self = .timeout
        case .cannotConnectToHost: self = .refused
        case .cannotFindHost, .dnsLookupFailed: self = .unreachable
        case .notConnectedToInternet, .networkConnectionLost: self = .notOnSameNetwork
        case .cancelled: self = .connectionLost
        default: self = .protocolError("URL error \(error.code.rawValue)")
        }
    }
}
