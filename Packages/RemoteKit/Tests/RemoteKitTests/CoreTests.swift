import Foundation
import Network
import Testing
@testable import RemoteCore
@testable import RemoteDrivers

@Suite("Core")
struct CoreTests {
    @Test func backoffDoublesAndCaps() {
        let backoff = Backoff()
        #expect(backoff.delay(forAttempt: 0) == .milliseconds(500))
        #expect(backoff.delay(forAttempt: 1) == .seconds(1))
        #expect(backoff.delay(forAttempt: 2) == .seconds(2))
        #expect(backoff.delay(forAttempt: 3) == .seconds(4))
        #expect(backoff.delay(forAttempt: 6) == .seconds(30))
        #expect(backoff.delay(forAttempt: 500) == .seconds(30))
        #expect(backoff.delay(forAttempt: -1) == .milliseconds(500))
    }

    @Test func touchpadEmitsOneKeyPerStep() {
        var pad = TouchpadInterpreter(sensitivity: 1)
        pad.begin()
        let step = pad.stepDistance
        #expect(pad.update(translationX: step * 0.5, translationY: 0).isEmpty)
        #expect(pad.update(translationX: step * 1.1, translationY: 4) == [.right])
        #expect(pad.update(translationX: step * 1.5, translationY: 4).isEmpty)
        #expect(pad.update(translationX: step * 3.2, translationY: 4) == [.right, .right])
        #expect(pad.update(translationX: step * 3.2, translationY: -step * 1.4) == [.up])
    }

    @Test func touchpadSensitivityScalesStep() {
        #expect(TouchpadInterpreter(sensitivity: 2).stepDistance < TouchpadInterpreter(sensitivity: 1).stepDistance)
        #expect(TouchpadInterpreter(sensitivity: 100).stepDistance == TouchpadInterpreter.baseStep / 4)
    }

    @Test func touchpadTapDetection() {
        #expect(TouchpadInterpreter.isTap(translationX: 2, translationY: 3, duration: 0.1))
        #expect(!TouchpadInterpreter.isTap(translationX: 30, translationY: 0, duration: 0.1))
        #expect(!TouchpadInterpreter.isTap(translationX: 0, translationY: 0, duration: 0.8))
    }

    @Test(arguments: [
        ("", "hello", 0, "hello"),
        ("hello", "hello!", 0, "!"),
        ("hello", "help", 2, "p"),
        ("hello", "", 5, ""),
        ("héllo", "héllö", 1, "ö"),
        ("abc", "abc", 0, ""),
    ])
    func textDiff(old: String, new: String, deletes: Int, insert: String) {
        #expect(TextDiff.edit(from: old, to: new) == TextDiff.Edit(deleteCount: deletes, insertion: insert))
    }

    @Test func macNormalization() {
        #expect(DeviceDescriptor.normalizeMAC("D8-31-54-33-2D-7E") == "d8:31:54:33:2d:7e")
        #expect(DeviceDescriptor.normalizeMAC("d83154332d7e") == "d8:31:54:33:2d:7e")
        #expect(DeviceDescriptor.normalizeMAC("00:00:00:00:00:00") == nil)
        #expect(DeviceDescriptor.normalizeMAC("nope") == nil)
    }

    @Test func everyErrorHasAMessage() {
        let errors: [DriverError] = [
            .notOnSameNetwork, .localNetworkDenied, .unreachable, .refused, .timeout, .connectionLost,
            .pairingRequired, .pairingRejected, .pairingCodeMismatch, .pairingTimedOut,
            .rokuMobileControlDisabled, .unsupported("x"), .tvError("x"), .protocolError("x"),
        ]
        for error in errors {
            #expect(!error.userMessage.isEmpty)
        }
        #expect(DriverError.rokuMobileControlDisabled.recoverySuggestion?.contains("Control by mobile apps") == true)
    }

    @Test func networkErrorsMapToActionableCases() {
        #expect(DriverError(NWError.posix(.ECONNREFUSED)) == .refused)
        #expect(DriverError(NWError.posix(.ENETUNREACH)) == .notOnSameNetwork)
        #expect(DriverError(NWError.dns(-65570)) == .localNetworkDenied)
        #expect(DriverError(URLError(.timedOut)) == .timeout)
        #expect(DriverError(URLError(.cannotConnectToHost)) == .refused)
    }

    @Test func broadcasterReplaysCurrentValueToNewListeners() async {
        let broadcaster = StateBroadcaster<ConnectionState>(.disconnected)
        broadcaster.send(.connecting)
        let stream = broadcaster.stream()
        broadcaster.send(.connected)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .connecting)
        #expect(await iterator.next() == .connected)
    }

    @Test func commandQueuePreservesOrderUnderBursts() async throws {
        let driver = MockTVDriver(latency: .milliseconds(1))
        try await driver.connect()
        let queue = CommandQueue(driver: driver) { _ in }
        let keys: [RemoteKey] = [.up, .up, .right, .down, .select, .back, .left, .home]
        for key in keys { queue.enqueue(.key(key, .press)) }
        queue.enqueue(.text("hi"))

        let expected = keys.map { RemoteCommand.key($0, .press) } + [.text("hi")]
        for _ in 0..<200 {
            if await driver.sentCommands.count >= expected.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await driver.sentCommands == expected)
        #expect(await driver.typedText == "hi")
    }

    @Test func commandQueueReportsErrors() async throws {
        let driver = MockTVDriver(latency: .milliseconds(1))
        let errors = Locked<[DriverError]>([])
        let queue = CommandQueue(driver: driver) { error in errors.withLock { $0.append(error) } }
        queue.enqueue(.key(.up, .press)) // not connected yet
        for _ in 0..<200 where errors.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(errors.withLock { $0 } == [.connectionLost])
    }

    @Test func keepAliveReconnectsAfterDrop() async throws {
        let driver = MockTVDriver(latency: .milliseconds(1))
        try await driver.connect()
        let keepAlive = KeepAlive(
            driver: driver,
            heartbeatInterval: .seconds(60),
            backoff: Backoff(base: .milliseconds(10), maximum: .milliseconds(50))
        )
        await keepAlive.start()
        await driver.simulateDrop()

        var reconnected = false
        for _ in 0..<200 {
            if await driver.state.firstValue == .connected {
                reconnected = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await keepAlive.stop()
        #expect(reconnected)
    }
}
