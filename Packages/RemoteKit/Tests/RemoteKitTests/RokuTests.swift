import Foundation
import Testing
@testable import RemoteCore
@testable import RemoteDrivers

@Suite("Roku ECP")
struct RokuTests {
    @Test func navigationKeysUseECPNames() {
        #expect(ECPKeyMap.name(for: .up) == "Up")
        #expect(ECPKeyMap.name(for: .select) == "Select")
        #expect(ECPKeyMap.name(for: .playPause) == "Play")
        #expect(ECPKeyMap.name(for: .rewind) == "Rev")
        #expect(ECPKeyMap.name(for: .mute) == "VolumeMute")
        #expect(ECPKeyMap.name(for: .backspace) == "Backspace")
        #expect(ECPKeyMap.name(for: .next) == nil)
    }

    @Test(arguments: [
        ("a", "Lit_a"),
        ("Z", "Lit_Z"),
        ("7", "Lit_7"),
        (" ", "Lit_%20"),
        ("&", "Lit_%26"),
        ("/", "Lit_%2F"),
        ("?", "Lit_%3F"),
        ("é", "Lit_%C3%A9"),
        ("😀", "Lit_%F0%9F%98%80"),
    ])
    func literalKeysArePercentEncoded(character: String, expected: String) throws {
        #expect(ECPKeyMap.literal(try #require(character.first)) == expected)
    }

    @Test func deviceInfoParsesStreamingStick() throws {
        let info = try RokuXML.deviceInfo(try Fixtures.data("roku-device-info", "xml"))
        #expect(info.serialNumber == "X01900ABCDEF")
        #expect(info.friendlyName == "Living Room Roku")
        #expect(info.isTV == false)

        let device = info.descriptor(host: "192.168.1.40", port: 8060)
        #expect(device.id == "roku/serial/x01900abcdef")
        #expect(device.name == "Living Room Roku")
        #expect(device.mac == "d8:31:54:33:2d:7e")
        #expect(device.platform == .roku)
    }

    @Test func deviceInfoParsesRokuTV() throws {
        let info = try RokuXML.deviceInfo(try Fixtures.data("roku-device-info-tv", "xml"))
        #expect(info.isTV)
        // An empty user-device-name falls back to the friendly name.
        #expect(info.friendlyName == "Bedroom TV")
        // An all-zero Wi-Fi MAC is ignored in favor of the Ethernet MAC.
        #expect(info.descriptor(host: "10.0.0.5", port: 8060).mac == "c8:3a:6b:11:22:33")
    }

    @Test func appListSkipsMenuAndBuildsIconURLs() throws {
        let base = try #require(URL(string: "http://192.168.1.40:8060/"))
        let apps = try RokuXML.apps(try Fixtures.data("roku-apps", "xml"), iconBase: base)
        #expect(apps.map(\.id) == ["12", "837", "2213", "tvinput.hdmi1", "13535"])
        #expect(apps.last?.name == "Plex & Friends")
        #expect(apps.first?.iconURL?.absoluteString == "http://192.168.1.40:8060/query/icon/12")
    }

    @Test func malformedDeviceInfoThrows() {
        #expect(throws: DriverError.self) {
            try RokuXML.deviceInfo(Data("<apps></apps>".utf8))
        }
    }
}
