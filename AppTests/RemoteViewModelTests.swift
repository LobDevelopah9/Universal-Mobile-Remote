import Foundation
import RemoteCore
import RemoteDrivers
import Testing
@testable import Remote

/// Drives the real view model against `MockTVDriver`, the same path the UI uses.
@MainActor
@Suite("RemoteViewModel", .serialized)
struct RemoteViewModelTests {
    private func makeSession(capabilities: TVCapabilities? = nil) async throws -> (RemoteViewModel, MockTVDriver) {
        let driver = MockTVDriver(latency: .milliseconds(1))
        if let capabilities { await driver.setCapabilities(capabilities) }
        try await driver.connect()
        let session = RemoteViewModel(device: MockTVDriver.demoDevice, driver: driver, alreadyConnected: true)
        session.start()
        try await waitUntil { session.state == .connected && !session.capabilities.isEmpty }
        return (session, driver)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for condition")
    }

    @Test func pressesReachTheTVInOrder() async throws {
        let (session, driver) = try await makeSession()
        session.press(.up)
        session.press(.right)
        session.press(.select)
        try await waitUntil { await driver.sentCommands.count >= 3 }
        #expect(await driver.sentCommands == [.key(.up, .press), .key(.right, .press), .key(.select, .press)])
        session.close()
    }

    @Test func typingStreamsDiffs() async throws {
        let (session, driver) = try await makeSession()
        session.beginTyping()
        session.typingChanged(to: "net")
        session.typingChanged(to: "netf")
        session.typingChanged(to: "ne")
        try await waitUntil { await driver.sentCommands.count >= 4 }
        #expect(await driver.typedText == "ne")
        session.close()
    }

    @Test func touchpadBecomesArrowKeysWithoutNativeTouch() async throws {
        let (session, driver) = try await makeSession(capabilities: [.dpad, .keyboard])
        session.touchpadBegan()
        session.touchpadMoved(CGSize(width: TouchpadInterpreter.baseStep * 2.2, height: 0))
        session.touchpadEnded(CGSize(width: TouchpadInterpreter.baseStep * 2.2, height: 0), duration: 0.5)
        try await waitUntil { await driver.sentCommands.count >= 2 }
        #expect(await driver.sentCommands == [.key(.right, .press), .key(.right, .press)])
        session.close()
    }

    @Test func tapOnTouchpadSelects() async throws {
        let (session, driver) = try await makeSession()
        session.touchpadBegan()
        session.touchpadEnded(.zero, duration: 0.1)
        try await waitUntil { await driver.sentCommands.count >= 1 }
        #expect(await driver.sentCommands == [.key(.select, .press)])
        session.close()
    }

    @Test func capabilitiesComeFromTheDriver() async throws {
        let (session, _) = try await makeSession(capabilities: [.dpad, .volume])
        #expect(session.capabilities == [.dpad, .volume])
        #expect(session.apps.isEmpty)
        session.close()
    }

    @Test func appsLoadWhenSupported() async throws {
        let (session, driver) = try await makeSession()
        try await waitUntil { !session.apps.isEmpty }
        session.launch(session.apps[0])
        try await waitUntil { await driver.sentCommands.count >= 1 }
        #expect(await driver.sentCommands == [.launch(appID: "demo.video")])
        session.close()
    }

    @Test func droppedConnectionShowsReconnectingNotAnAlert() async throws {
        let (session, driver) = try await makeSession()
        await driver.simulateDrop()
        try await waitUntil { session.state != .connected }
        #expect(session.alert == nil)
        try await waitUntil { session.state == .connected }
        session.close()
    }
}
