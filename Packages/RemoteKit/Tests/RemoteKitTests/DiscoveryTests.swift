import Foundation
import Testing
@testable import RemoteCore
@testable import RemoteDiscovery

@Suite("Discovery")
struct DiscoveryTests {
    @Test func mergerDeduplicatesProbeAndBonjourSightings() {
        var merger = DeviceMerger()
        let fromProbe = DeviceDescriptor(name: "Android TV (192.168.1.20)", platform: .androidTV, host: "192.168.1.20", port: 6466)
        let fromBonjour = DeviceDescriptor(name: "Living Room TV", platform: .androidTV, host: "192.168.1.20", port: 6466, mac: "AA:BB:CC:DD:EE:FF")

        let insertedProbe = merger.insert(fromProbe)
        let mergedBonjour = merger.insert(fromBonjour)
        #expect(insertedProbe)
        #expect(mergedBonjour)
        #expect(merger.devices.count == 1)
        #expect(merger.devices[0].name == "Living Room TV")
        #expect(merger.devices[0].id == "androidTV/mac/aa:bb:cc:dd:ee:ff")

        // A later placeholder sighting must not overwrite the real name or the stable ID.
        let changedAgain = merger.insert(fromProbe)
        #expect(!changedAgain)
        #expect(merger.devices[0].name == "Living Room TV")
        #expect(merger.devices[0].id == "androidTV/mac/aa:bb:cc:dd:ee:ff")
    }

    @Test func mergerFollowsADeviceToANewAddress() {
        var merger = DeviceMerger()
        let roku = DeviceDescriptor(id: "roku/serial/x1", name: "Den", platform: .roku, host: "10.0.0.5", port: 8060)
        var moved = roku
        moved.host = "10.0.0.9"
        merger.insert(roku)
        let followed = merger.insert(moved)
        #expect(followed)
        #expect(merger.devices.map(\.host) == ["10.0.0.9"])
    }

    @Test func differentPlatformsOnOneHostStaySeparate() {
        var merger = DeviceMerger()
        merger.insert(DeviceDescriptor(name: "A", platform: .roku, host: "10.0.0.5", port: 8060))
        merger.insert(DeviceDescriptor(name: "B", platform: .androidTV, host: "10.0.0.5", port: 6466))
        #expect(merger.devices.count == 2)
    }

    @Test func sweepCoversOwnSlash24Only() throws {
        let home = try #require(IPv4Interface(name: "en0", address: "192.168.1.37", netmask: "255.255.255.0"))
        let hosts = home.sweepHosts
        #expect(hosts.count == 253)
        #expect(hosts.first == "192.168.1.1")
        #expect(hosts.last == "192.168.1.254")
        #expect(!hosts.contains("192.168.1.37"))

        let office = try #require(IPv4Interface(name: "en0", address: "10.20.30.40", netmask: "255.255.0.0"))
        #expect(office.sweepHosts.count == 253)
        #expect(office.sweepHosts.allSatisfy { $0.hasPrefix("10.20.30.") })

        let tiny = try #require(IPv4Interface(name: "en0", address: "172.16.0.1", netmask: "255.255.255.252"))
        #expect(tiny.sweepHosts == ["172.16.0.2"])
    }

    @Test func ssdpRokuResponseParses() throws {
        let text = """
        HTTP/1.1 200 OK\r
        Cache-Control: max-age=3600\r
        ST: roku:ecp\r
        USN: uuid:roku:ecp:X01900ABCDEF\r
        Ext: \r
        Server: Roku/12.5.0 UPnP/1.0 Roku/12.5.0\r
        LOCATION: http://192.168.1.40:8060/\r
        \r

        """
        let response = try #require(SSDPResponse(text))
        #expect(response.isRoku)
        #expect(response.location.host == "192.168.1.40")
        #expect(response.location.port == 8060)
        #expect(response.usn == "uuid:roku:ecp:X01900ABCDEF")
    }

    @Test func ssdpWithoutLocationIsIgnored() {
        #expect(SSDPResponse("HTTP/1.1 200 OK\r\nST: roku:ecp\r\n\r\n") == nil)
    }

    @Test func serviceRunsSourcesAndMerges() async throws {
        struct FakeSource: DiscoverySource {
            let devices: [DeviceDescriptor]
            func run(emit: @escaping @Sendable (DiscoveryEvent) async -> Void) async {
                for device in devices { await emit(.found(device, source: .manual)) }
            }
        }
        let tv = DeviceDescriptor(name: "Android TV (10.0.0.2)", platform: .androidTV, host: "10.0.0.2", port: 6466)
        var named = tv
        named.name = "Kitchen"
        let service = DiscoveryService(sources: [FakeSource(devices: [tv]), FakeSource(devices: [named])])
        let snapshots = await service.snapshots
        await service.start()

        var latest = DiscoverySnapshot.empty
        for await snapshot in snapshots {
            latest = snapshot
            if snapshot.devices.first?.name == "Kitchen" { break }
        }
        await service.stop()
        #expect(latest.devices.count == 1)
        #expect(latest.devices.first?.name == "Kitchen")
    }
}
