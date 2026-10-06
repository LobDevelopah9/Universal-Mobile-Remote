import Foundation
import Observation
import RemoteCore
import SwiftData

/// A TV the user has paired with. Secrets are not stored here; they live in Keychain.
@Model
public final class SavedDevice {
    @Attribute(.unique) public var id: String
    public var name: String
    public var platformRaw: String
    public var host: String
    public var port: Int
    public var mac: String?
    public var model: String?
    public var lastUsed: Date
    public var sortIndex: Int

    public init(_ descriptor: DeviceDescriptor, sortIndex: Int) {
        id = descriptor.id
        name = descriptor.name
        platformRaw = descriptor.platform.rawValue
        host = descriptor.host
        port = descriptor.port
        mac = descriptor.mac
        model = descriptor.model
        lastUsed = .now
        self.sortIndex = sortIndex
    }

    public var platform: TVPlatform { TVPlatform(rawValue: platformRaw) ?? .demo }

    public var descriptor: DeviceDescriptor {
        DeviceDescriptor(id: id, name: name, platform: platform, host: host, port: port, mac: mac, model: model)
    }
}

/// Saved and paired devices plus the last-used one. All mutation happens on the main actor.
@MainActor
@Observable
public final class DeviceStore {
    public private(set) var devices: [DeviceDescriptor] = []
    public let credentials: CredentialStore

    private let context: ModelContext

    public init(container: ModelContainer, credentials: CredentialStore = CredentialStore()) {
        context = ModelContext(container)
        context.autosaveEnabled = false
        self.credentials = credentials
        reload()
    }

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: SavedDevice.self, configurations: configuration)
    }

    /// Most recently used first.
    public var lastUsed: DeviceDescriptor? { devices.first }

    public func contains(_ id: String) -> Bool { devices.contains { $0.id == id } }

    /// Insert or update a device and its credentials, and mark it as most recently used.
    public func save(_ descriptor: DeviceDescriptor, credentials newCredentials: PairingCredentials?) throws {
        if let newCredentials {
            try credentials.save(newCredentials, for: descriptor.id)
        }
        if let existing = fetch(descriptor.id) {
            existing.host = descriptor.host
            existing.port = descriptor.port
            existing.mac = descriptor.mac ?? existing.mac
            existing.model = descriptor.model ?? existing.model
            existing.lastUsed = .now
        } else {
            context.insert(SavedDevice(descriptor, sortIndex: devices.count))
        }
        try context.save()
        reload()
    }

    public func markUsed(_ id: String) {
        guard let device = fetch(id) else { return }
        device.lastUsed = .now
        try? context.save()
        reload()
    }

    /// Discovery found a known TV at a new address (DHCP moved it).
    public func updateAddress(_ id: String, host: String, port: Int) {
        guard let device = fetch(id), device.host != host || device.port != port else { return }
        device.host = host
        device.port = port
        try? context.save()
        reload()
    }

    public func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let device = fetch(id) else { return }
        device.name = trimmed
        try? context.save()
        reload()
    }

    public func forget(_ id: String) {
        credentials.remove(for: id)
        if let device = fetch(id) {
            context.delete(device)
            try? context.save()
        }
        reload()
    }

    private func fetch(_ id: String) -> SavedDevice? {
        var descriptor = FetchDescriptor<SavedDevice>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func reload() {
        let descriptor = FetchDescriptor<SavedDevice>(sortBy: [SortDescriptor(\.lastUsed, order: .reverse)])
        devices = ((try? context.fetch(descriptor)) ?? []).map(\.descriptor)
    }
}
