import Foundation
import Security
import Testing
@testable import RemoteCore
@testable import RemoteDrivers

/// Every expected byte here was captured from the reference `androidtvremote2`
/// implementation by tools/fixtures/gen_androidtv_fixtures.py.
@Suite("Android TV Remote v2")
struct AndroidTVTests {
    let fixture: Fixtures.AndroidTV

    init() throws {
        fixture = try Fixtures.androidTV()
    }

    // MARK: Pairing secret

    @Test func pairingSecretMatchesReference() throws {
        let client = try RSAPublicNumbers(certificateDER: Array(Data(hex: fixture.clientCertDer)))
        let server = try RSAPublicNumbers(certificateDER: Array(Data(hex: fixture.serverCertDer)))
        let secret = try PairingSecret.compute(client: client, server: server, code: fixture.pairing.code)
        #expect(secret.hex == fixture.pairing.secret)
    }

    @Test func pairingSecretIsCaseInsensitive() throws {
        let client = try RSAPublicNumbers(certificateDER: Array(Data(hex: fixture.clientCertDer)))
        let server = try RSAPublicNumbers(certificateDER: Array(Data(hex: fixture.serverCertDer)))
        let secret = try PairingSecret.compute(client: client, server: server, code: fixture.pairing.code.lowercased())
        #expect(secret.hex == fixture.pairing.secret)
    }

    @Test func mistypedCodeIsRejectedLocally() throws {
        let client = try RSAPublicNumbers(certificateDER: Array(Data(hex: fixture.clientCertDer)))
        let server = try RSAPublicNumbers(certificateDER: Array(Data(hex: fixture.serverCertDer)))
        #expect(throws: DriverError.pairingCodeMismatch) {
            try PairingSecret.compute(client: client, server: server, code: fixture.pairing.mismatchedCode)
        }
    }

    @Test(arguments: ["", "12345", "1234567", "GHIJKL", "12 345"])
    func malformedCodesAreRejected(code: String) throws {
        #expect(throws: DriverError.pairingCodeMismatch) { try PairingSecret.decode(code) }
    }

    @Test func secretMessageMatchesReference() throws {
        let secret = Data(hex: fixture.pairing.secret)
        let framed = try AndroidTVMessages.framed(AndroidTVMessages.secret(secret))
        #expect(framed.hex == (try fixture.message("secret")).framed)
    }

    // MARK: RSA key parsing

    @Test func certificateAndPKCS1ParsingAgree() throws {
        let key = try makeEphemeralRSAKey()
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let fromKey = try RSAPublicNumbers(publicKeyDER: Array(pkcs1))

        let certificate = try SelfSignedCertificate.make(privateKey: key, commonName: "atvremote")
        let fromCertificate = try RSAPublicNumbers(certificateDER: Array(certificate))

        #expect(fromKey == fromCertificate)
        #expect(fromKey.modulus.count == 256)
        #expect(fromKey.exponent == [0x01, 0x00, 0x01])
        #expect(SecCertificateCreateWithData(nil, certificate as CFData) != nil)
    }

    // MARK: Message encoding

    @Test func pairingHandshakeMessagesMatchReference() throws {
        #expect(try AndroidTVMessages.framed(AndroidTVMessages.pairingRequest(clientName: "Remote")).hex
            == (try fixture.message("pairing_request")).framed)
        #expect(try AndroidTVMessages.framed(AndroidTVMessages.options()).hex
            == (try fixture.message("options")).framed)
        #expect(try AndroidTVMessages.framed(AndroidTVMessages.configuration()).hex
            == (try fixture.message("configuration")).framed)
    }

    @Test func pairingRepliesDecode() throws {
        let ack = try Polo_Wire_Protobuf_OuterMessage(serializedBytes: Data(hex: try fixture.message("pairing_request_ack").payload))
        #expect(ack.status == .ok)
        #expect(ack.hasPairingRequestAck)
        #expect(ack.pairingRequestAck.serverName == "Living Room TV")

        let configAck = try Polo_Wire_Protobuf_OuterMessage(serializedBytes: Data(hex: try fixture.message("configuration_ack").payload))
        #expect(configAck.hasConfigurationAck)
    }

    @Test func configureHandshakeMatchesReference() throws {
        let incoming = try Remote_RemoteMessage(serializedBytes: Data(hex: try fixture.message("remote_configure_from_tv").payload))
        #expect(incoming.hasRemoteConfigure)
        #expect(incoming.remoteConfigure.deviceInfo.vendor == "Fixture Co")

        let reply = AndroidTVMessages.configureResponse(tvFeatures: incoming.remoteConfigure.code1)
        #expect(try AndroidTVMessages.framed(reply).hex == (try fixture.message("remote_configure")).framed)

        let active = AndroidTVMessages.setActive(reply.remoteConfigure.code1)
        #expect(try AndroidTVMessages.framed(active).hex == (try fixture.message("remote_set_active")).framed)
    }

    @Test func pingIsAnsweredLikeReference() throws {
        let ping = try Remote_RemoteMessage(serializedBytes: Data(hex: try fixture.message("remote_ping_request").payload))
        #expect(ping.hasRemotePingRequest)
        let pong = AndroidTVMessages.pingResponse(ping.remotePingRequest.val1)
        #expect(try AndroidTVMessages.framed(pong).hex == (try fixture.message("remote_ping_response")).framed)
    }

    @Test func keyInjectionMatchesReference() throws {
        let cases: [(String, RemoteKey, Remote_RemoteDirection)] = [
            ("key_dpad_up_short", .up, .short),
            ("key_dpad_center_start_long", .select, .startLong),
            ("key_dpad_center_end_long", .select, .endLong),
            ("key_volume_up_short", .volumeUp, .short),
        ]
        for (name, key, direction) in cases {
            let message = AndroidTVMessages.key(AndroidTVKeyMap.code(for: key), direction: direction)
            #expect(try AndroidTVMessages.framed(message).hex == (try fixture.message(name)).framed, "\(name)")
        }
    }

    @Test func imeTextMatchesReference() throws {
        let fromTV = try Remote_RemoteMessage(serializedBytes: Data(hex: try fixture.message("remote_ime_batch_edit_from_tv").payload))
        let message = AndroidTVMessages.imeText(
            "hello",
            imeCounter: fromTV.remoteImeBatchEdit.imeCounter,
            fieldCounter: fromTV.remoteImeBatchEdit.fieldCounter
        )
        #expect(try AndroidTVMessages.framed(message).hex == (try fixture.message("ime_text_hello")).framed)
    }

    @Test func appLinkMatchesReference() throws {
        let message = AndroidTVMessages.appLink("https://www.youtube.com")
        #expect(try AndroidTVMessages.framed(message).hex == (try fixture.message("app_link_launch")).framed)
    }

    @Test func tvStateMessagesDecode() throws {
        let start = try Remote_RemoteMessage(serializedBytes: Data(hex: try fixture.message("remote_start").payload))
        #expect(start.hasRemoteStart && start.remoteStart.started)

        let volume = try Remote_RemoteMessage(serializedBytes: Data(hex: try fixture.message("remote_set_volume_level").payload))
        #expect(volume.remoteSetVolumeLevel.volumeLevel == 23)
        #expect(volume.remoteSetVolumeLevel.volumeMax == 100)
    }

    // MARK: Framing

    @Test func framerHandlesSplitReads() throws {
        let messages = fixture.messages.compactMap(\.framed).map { Data(hex: $0) }
        let stream = messages.reduce(Data(), +)
        var framer = VarintFramer()
        var received: [Data] = []
        // Feed one byte at a time so splits land inside every varint and payload.
        for byte in stream {
            received += try framer.append(Data([byte]))
        }
        #expect(received.count == messages.count)
        for (index, message) in messages.enumerated() {
            let payload = try #require(try VarintFramer.decodeVarint(message))
            #expect(received[index] == message.dropFirst(payload.size))
        }
    }

    @Test func framerHandlesManyMessagesInOneRead() throws {
        let payloads = [Data(repeating: 0xAB, count: 3), Data(repeating: 0xCD, count: 300), Data()]
        var framer = VarintFramer()
        let received = try framer.append(payloads.map(VarintFramer.frame).reduce(Data(), +))
        #expect(received == payloads)
    }

    @Test func varintRoundTrips() throws {
        for value in [0, 1, 127, 128, 300, 16_383, 16_384, 1 << 20] {
            let encoded = VarintFramer.encodeVarint(UInt64(value))
            let decoded = try #require(try VarintFramer.decodeVarint(encoded))
            #expect(decoded.value == value)
            #expect(decoded.size == encoded.count)
        }
    }

    @Test func oversizedFrameIsRejected() throws {
        var framer = VarintFramer()
        #expect(throws: DriverError.self) {
            _ = try framer.append(VarintFramer.encodeVarint(UInt64(VarintFramer.maximumMessageSize + 1)))
        }
    }

    // MARK: Key map

    @Test func everyKeyHasAnAndroidCode() {
        for key in RemoteKey.allCases {
            #expect(AndroidTVKeyMap.code(for: key) > 0)
        }
        #expect(AndroidTVKeyMap.code(for: "a") == 29)
        #expect(AndroidTVKeyMap.code(for: "Z") == 54)
        #expect(AndroidTVKeyMap.code(for: "0") == 7)
        #expect(AndroidTVKeyMap.code(for: "€") == nil)
    }

    private func makeEphemeralRSAKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }
}
