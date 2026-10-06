import Foundation

/// A family of TVs or streaming boxes that share one control protocol.
///
/// Labels are descriptive only. The app never uses vendor logos, and nothing here
/// implies the app is affiliated with or endorsed by any manufacturer.
public enum TVPlatform: String, Codable, Sendable, CaseIterable, Hashable {
    case roku
    case androidTV
    case samsung
    case lg
    case sony
    case vizio
    case fireTV
    case appleTV
    case demo

    public var displayName: String {
        switch self {
        case .roku: "Roku"
        case .androidTV: "Android TV / Google TV"
        case .samsung: "Samsung TV"
        case .lg: "LG TV"
        case .sony: "Sony TV"
        case .vizio: "Vizio TV"
        case .fireTV: "Fire TV"
        case .appleTV: "Apple TV"
        case .demo: "Demo TV"
        }
    }

    /// A generic SF Symbol. Deliberately not a brand mark.
    public var symbolName: String {
        switch self {
        case .roku, .fireTV, .appleTV: "tv.and.mediabox"
        case .androidTV: "play.tv"
        case .samsung, .lg, .sony, .vizio: "tv"
        case .demo: "sparkles.tv"
        }
    }

    public var pairingStyle: PairingStyle {
        switch self {
        case .roku, .demo: .automatic
        case .androidTV: .codeOnTV(length: 6, alphabet: .hexadecimal)
        case .samsung, .lg: .acceptOnTV
        case .sony, .vizio: .codeOnTV(length: 4, alphabet: .numeric)
        case .fireTV: .acceptOnTV
        case .appleTV: .codeOnTV(length: 4, alphabet: .numeric)
        }
    }

    /// Platforms with a working driver in this build.
    public var isSupported: Bool {
        switch self {
        case .roku, .androidTV, .demo: true
        default: false
        }
    }
}

public enum PairingStyle: Sendable, Equatable {
    /// No pairing step, e.g. Roku ECP.
    case automatic
    /// The TV shows a code that the user types into the phone.
    case codeOnTV(length: Int, alphabet: CodeAlphabet)
    /// The TV shows an allow/deny prompt.
    case acceptOnTV

    public enum CodeAlphabet: Sendable, Equatable {
        case numeric
        case hexadecimal

        public func accepts(_ character: Character) -> Bool {
            switch self {
            case .numeric: character.isASCII && character.isNumber
            case .hexadecimal: character.isHexDigit
            }
        }
    }
}
