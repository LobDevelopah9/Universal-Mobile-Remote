import Foundation
import RemoteCore
import SwiftProtobuf

/// Feature bits exchanged in RemoteConfigure / RemoteSetActive.
struct AndroidTVFeatures: OptionSet, Sendable {
    let rawValue: Int32
    static let ping = AndroidTVFeatures(rawValue: 1 << 0)
    static let key = AndroidTVFeatures(rawValue: 1 << 1)
    static let ime = AndroidTVFeatures(rawValue: 1 << 2)
    static let voice = AndroidTVFeatures(rawValue: 1 << 3)
    static let power = AndroidTVFeatures(rawValue: 1 << 5)
    static let volume = AndroidTVFeatures(rawValue: 1 << 6)
    static let appLink = AndroidTVFeatures(rawValue: 1 << 9)

    /// What this client asks for. Voice is not supported.
    static let requested: AndroidTVFeatures = [.ping, .key, .ime, .power, .volume, .appLink]
}

/// Builds the exact messages the TV expects. Kept free of I/O so tests can compare
/// bytes against fixtures captured from the reference implementation.
enum AndroidTVMessages {
    static let serviceName = "atvremote"
    static let packageName = "atvremote"
    static let appVersion = "1.0.0"
    static let protocolVersion: UInt32 = 2

    // MARK: Pairing (Polo, port 6467)

    static func outer(_ configure: (inout Polo_Wire_Protobuf_OuterMessage) -> Void) -> Polo_Wire_Protobuf_OuterMessage {
        var message = Polo_Wire_Protobuf_OuterMessage()
        message.protocolVersion = protocolVersion
        message.status = .ok
        configure(&message)
        return message
    }

    static func pairingRequest(clientName: String) -> Polo_Wire_Protobuf_OuterMessage {
        outer {
            $0.pairingRequest.serviceName = serviceName
            $0.pairingRequest.clientName = clientName
        }
    }

    static func options() -> Polo_Wire_Protobuf_OuterMessage {
        outer {
            var encoding = Polo_Wire_Protobuf_Options.Encoding()
            encoding.type = .hexadecimal
            encoding.symbolLength = 6
            $0.options.inputEncodings = [encoding]
            $0.options.preferredRole = .input
        }
    }

    static func configuration() -> Polo_Wire_Protobuf_OuterMessage {
        outer {
            $0.configuration.encoding.type = .hexadecimal
            $0.configuration.encoding.symbolLength = 6
            $0.configuration.clientRole = .input
        }
    }

    static func secret(_ secret: Data) -> Polo_Wire_Protobuf_OuterMessage {
        outer { $0.secret.secret = secret }
    }

    // MARK: Remote (port 6466)

    static func configureResponse(tvFeatures: Int32) -> Remote_RemoteMessage {
        var message = Remote_RemoteMessage()
        message.remoteConfigure.code1 = AndroidTVFeatures.requested.rawValue & tvFeatures
        message.remoteConfigure.deviceInfo.unknown1 = 1
        message.remoteConfigure.deviceInfo.unknown2 = "1"
        message.remoteConfigure.deviceInfo.packageName = packageName
        message.remoteConfigure.deviceInfo.appVersion = appVersion
        return message
    }

    static func setActive(_ features: Int32) -> Remote_RemoteMessage {
        var message = Remote_RemoteMessage()
        message.remoteSetActive.active = features
        return message
    }

    static func pingResponse(_ value: Int32) -> Remote_RemoteMessage {
        var message = Remote_RemoteMessage()
        message.remotePingResponse.val1 = value
        return message
    }

    static func key(_ code: Int, direction: Remote_RemoteDirection) -> Remote_RemoteMessage {
        var message = Remote_RemoteMessage()
        message.remoteKeyInject.keyCode = Remote_RemoteKeyCode(rawValue: code) ?? .UNRECOGNIZED(code)
        message.remoteKeyInject.direction = direction
        return message
    }

    /// Replaces the focused text field's content with `text` (cursor at the end).
    static func imeText(_ text: String, imeCounter: Int32, fieldCounter: Int32) -> Remote_RemoteMessage {
        var object = Remote_RemoteImeObject()
        // Android text positions are UTF-16 offsets.
        let cursor = Int32(text.utf16.count - 1)
        object.start = cursor
        object.end = cursor
        object.value = text
        var edit = Remote_RemoteEditInfo()
        edit.insert = 1
        edit.textFieldStatus = object
        var message = Remote_RemoteMessage()
        message.remoteImeBatchEdit.imeCounter = imeCounter
        message.remoteImeBatchEdit.fieldCounter = fieldCounter
        message.remoteImeBatchEdit.editInfo = [edit]
        return message
    }

    static func appLink(_ link: String) -> Remote_RemoteMessage {
        var message = Remote_RemoteMessage()
        message.remoteAppLinkLaunchRequest.appLink = link
        return message
    }

    static func framed(_ message: some SwiftProtobuf.Message) throws -> Data {
        VarintFramer.frame(try message.serializedData())
    }
}

/// Android `KeyEvent` codes, as listed in remotemessage.proto.
enum AndroidTVKeyMap {
    static func code(for key: RemoteKey) -> Int {
        switch key {
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .select: 23
        case .back: 4
        case .home: 3
        case .menu: 82
        case .playPause: 85
        case .rewind: 89
        case .fastForward: 90
        case .next: 87
        case .previous: 88
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        case .power: 26
        case .powerOn: 224 // KEYCODE_WAKEUP
        case .powerOff: 223 // KEYCODE_SLEEP
        case .channelUp: 166
        case .channelDown: 167
        case .info: 165
        case .search: 84
        case .input: 178
        case .backspace: 67
        case .enter: 66
        }
    }

    /// Fallback text entry for when no IME field is open: ASCII letters, digits, space.
    static func code(for character: Character) -> Int? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return 29 + Int(ascii - UInt8(ascii: "a"))
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return 29 + Int(ascii - UInt8(ascii: "A"))
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return 7 + Int(ascii - UInt8(ascii: "0"))
        case UInt8(ascii: " "): return 62
        case UInt8(ascii: "."): return 56
        case UInt8(ascii: ","): return 55
        case UInt8(ascii: "-"): return 69
        case UInt8(ascii: "@"): return 77
        case UInt8(ascii: "\n"): return 66
        default: return nil
        }
    }
}

/// Deep links for common streaming apps. The protocol can't list installed apps,
/// so this is a starting set; links to apps that aren't installed open the store.
enum AndroidTVAppLinks {
    static let common: [TVApp] = [
        TVApp(id: "https://www.youtube.com", name: "YouTube"),
        TVApp(id: "https://www.netflix.com/title", name: "Netflix"),
        TVApp(id: "https://app.primevideo.com", name: "Prime Video"),
        TVApp(id: "https://www.disneyplus.com", name: "Disney+"),
        TVApp(id: "https://play.max.com", name: "Max"),
        TVApp(id: "https://tv.apple.com", name: "Apple TV app"),
        TVApp(id: "https://open.spotify.com", name: "Spotify"),
        TVApp(id: "https://www.twitch.tv", name: "Twitch"),
        TVApp(id: "https://www.plex.tv", name: "Plex"),
    ]
}
