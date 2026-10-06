import Foundation

public enum RemoteCommand: Sendable, Equatable {
    case key(RemoteKey, KeyAction)
    case text(String)
    case swipe(dx: Double, dy: Double)
    case launch(appID: String)
}

/// The fire-and-forget path from the UI to a driver.
///
/// `enqueue` is synchronous and non-blocking, so a button handler returns right away.
/// One consumer task drains commands in order. Spawning a `Task` per press could
/// reorder fast taps, so this does not.
public final class CommandQueue: Sendable {
    private let continuation: AsyncStream<RemoteCommand>.Continuation
    private let consumer: Task<Void, Never>

    /// - Parameter onError: Called for every failed command, off the main actor.
    public init(driver: any TVDriver, onError: @escaping @Sendable (DriverError) -> Void) {
        // Keep the newest commands if the TV stalls; a backlog of stale presses is worse than dropping.
        let (stream, continuation) = AsyncStream.makeStream(
            of: RemoteCommand.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.continuation = continuation
        consumer = Task {
            for await command in stream {
                do {
                    try await CommandQueue.execute(command, on: driver)
                } catch {
                    onError(DriverError(error))
                }
            }
        }
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }

    public func enqueue(_ command: RemoteCommand) {
        continuation.yield(command)
    }

    public func close() {
        continuation.finish()
    }

    static func execute(_ command: RemoteCommand, on driver: any TVDriver) async throws {
        switch command {
        case .key(let key, let action):
            try await driver.send(key, action: action)
        case .text(let text):
            try await driver.sendText(text)
        case .swipe(let dx, let dy):
            try await driver.swipe(dx: dx, dy: dy)
        case .launch(let appID):
            try await driver.launchApp(appID)
        }
    }
}
