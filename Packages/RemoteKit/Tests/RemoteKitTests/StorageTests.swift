import Foundation
import Testing
@testable import RemoteCore
@testable import RemoteStorage

@Suite("Storage")
@MainActor
struct StorageTests {
    @Test func savedDevicesAreOrderedByLastUse() throws {
        let store = DeviceStore(container: try DeviceStore.makeContainer(inMemory: true))
        let first = DeviceDescriptor(id: "roku/serial/a", name: "Den", platform: .roku, host: "10.0.0.2", port: 8060)
        let second = DeviceDescriptor(id: "roku/serial/b", name: "Bedroom", platform: .roku, host: "10.0.0.3", port: 8060)
        try store.save(first, credentials: nil)
        try store.save(second, credentials: nil)
        #expect(store.devices.map(\.id) == ["roku/serial/b", "roku/serial/a"])

        store.markUsed("roku/serial/a")
        #expect(store.lastUsed?.id == "roku/serial/a")
    }

    @Test func renameAddressUpdateAndForget() throws {
        let store = DeviceStore(container: try DeviceStore.makeContainer(inMemory: true))
        let device = DeviceDescriptor(id: "roku/serial/a", name: "Den", platform: .roku, host: "10.0.0.2", port: 8060)
        try store.save(device, credentials: nil)

        store.rename(device.id, to: "  Family Room ")
        #expect(store.devices.first?.name == "Family Room")
        store.rename(device.id, to: "   ")
        #expect(store.devices.first?.name == "Family Room")

        store.updateAddress(device.id, host: "10.0.0.99", port: 8060)
        #expect(store.devices.first?.host == "10.0.0.99")

        store.forget(device.id)
        #expect(store.devices.isEmpty)
    }

    @Test func savingAgainKeepsOneRecord() throws {
        let store = DeviceStore(container: try DeviceStore.makeContainer(inMemory: true))
        let device = DeviceDescriptor(id: "roku/serial/a", name: "Den", platform: .roku, host: "10.0.0.2", port: 8060)
        try store.save(device, credentials: nil)
        try store.save(device, credentials: nil)
        #expect(store.devices.count == 1)
    }
}
