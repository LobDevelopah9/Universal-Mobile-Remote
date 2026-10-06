import Foundation
import Testing
@testable import RemoteCore
@testable import RemoteDiscovery
@testable import RemoteDrivers

/// Runs `RokuDriver` against tools/fake_tv/roku_ecp.py. CI starts the server and sets
/// FAKE_ROKU_PORT. Locally:  python3 tools/fake_tv/roku_ecp.py --port 8060
@Suite(
    "Roku integration (fake TV)",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["FAKE_ROKU_PORT"] != nil)
)
struct RokuIntegrationTests {
    let port = Int(ProcessInfo.processInfo.environment["FAKE_ROKU_PORT"] ?? "8060") ?? 8060
    let host = "127.0.0.1"

    private func control(_ path: String, method: String = "POST") async throws -> Data {
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/_test/\(path)")!)
        request.httpMethod = method
        return try await URLSession.shared.data(for: request).0
    }

    private func log() async throws -> [String] {
        try JSONDecoder().decode([String].self, from: try await control("log", method: "GET"))
    }

    private func makeDriver() -> RokuDriver {
        RokuDriver(device: DeviceDescriptor(name: "Fake", platform: .roku, host: host, port: port), timeout: 2)
    }

    @Test func fingerprintIdentifiesTheFakeRoku() async throws {
        _ = try await control("reset")
        let device = try #require(await PlatformFingerprint.roku(host: host, port: port))
        #expect(device.id == "roku/serial/fake0000test")
        #expect(device.name == "Fake Roku")
    }

    @Test func connectReadsCapabilities() async throws {
        _ = try await control("reset")
        let driver = makeDriver()
        try await driver.connect()
        #expect(await driver.capabilities.contains(.volume))
        #expect(await driver.state.firstValue == .connected)
    }

    @Test func keysTextAndLaunchReachTheTV() async throws {
        _ = try await control("reset")
        let driver = makeDriver()
        try await driver.connect()
        try await driver.send(.up)
        try await driver.send(.select, action: .down)
        try await driver.send(.select, action: .up)
        try await driver.sendText("a b")
        try await driver.launchApp("12")
        #expect(try await log() == [
            "keypress/Up", "keydown/Select", "keyup/Select",
            "keypress/Lit_a", "keypress/Lit_%20", "keypress/Lit_b",
            "launch/12",
        ])
    }

    @Test func appsComeBackWithIcons() async throws {
        _ = try await control("reset")
        let apps = try await makeDriver().listApps()
        #expect(apps.map(\.name).contains("Netflix"))
        let icon = try #require(apps.first?.iconURL)
        let (data, response) = try await URLSession.shared.data(from: icon)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(!data.isEmpty)
    }

    @Test func limitedModeMapsToActionableError() async throws {
        _ = try await control("reset")
        _ = try await control("limited?on=1")
        let driver = makeDriver()
        try await driver.connect()
        await #expect(throws: DriverError.rokuMobileControlDisabled) {
            try await driver.send(.home)
        }
        #expect(await driver.state.firstValue == .error(.rokuMobileControlDisabled))
        _ = try await control("reset")
    }

    @Test func manualProbeFindsTheFakeRokuOnItsPort() async throws {
        _ = try await control("reset")
        // Manual entry probes the standard port, so only run this when the fake uses it.
        guard port == RokuDriver.defaultPort else { return }
        let found = await SubnetProbe.identify(host: host)
        #expect(found.contains { $0.platform == .roku })
    }
}
