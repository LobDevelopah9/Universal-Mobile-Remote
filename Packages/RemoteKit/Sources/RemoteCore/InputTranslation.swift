import Foundation

/// Turns a continuous touchpad drag into discrete D-pad presses for TVs that don't
/// accept native touch events. One key fires per `stepDistance` points along the
/// dominant axis. Drift on the other axis resets so diagonal swipes don't double-fire.
public struct TouchpadInterpreter: Sendable, Equatable {
    public static let baseStep: Double = 56

    public private(set) var stepDistance: Double
    private var anchorX: Double = 0
    private var anchorY: Double = 0

    /// - Parameter sensitivity: 0.5 (slow) … 2.0 (fast). Higher means fewer points per key.
    public init(sensitivity: Double = 1) {
        stepDistance = TouchpadInterpreter.baseStep / min(max(sensitivity, 0.25), 4)
    }

    public mutating func begin() {
        anchorX = 0
        anchorY = 0
    }

    /// Feed the drag's total translation since `begin()`. Returns the keys to send now.
    public mutating func update(translationX: Double, translationY: Double) -> [RemoteKey] {
        let dx = translationX - anchorX
        let dy = translationY - anchorY
        if abs(dx) >= abs(dy), abs(dx) >= stepDistance {
            let count = min(Int(abs(dx) / stepDistance), 6)
            let sign: Double = dx > 0 ? 1 : -1
            anchorX += Double(count) * stepDistance * sign
            anchorY = translationY
            return Array(repeating: dx > 0 ? .right : .left, count: count)
        }
        if abs(dy) > abs(dx), abs(dy) >= stepDistance {
            let count = min(Int(abs(dy) / stepDistance), 6)
            let sign: Double = dy > 0 ? 1 : -1
            anchorY += Double(count) * stepDistance * sign
            anchorX = translationX
            return Array(repeating: dy > 0 ? .down : .up, count: count)
        }
        return []
    }

    /// A touch that barely moved and lifted quickly counts as a tap (Select).
    public static func isTap(translationX: Double, translationY: Double, duration: TimeInterval) -> Bool {
        (translationX * translationX + translationY * translationY) < 100 && duration < 0.35
    }
}

/// Minimal edit from the previous keyboard text to the new one, so typing can be
/// streamed to the TV live as backspaces plus inserted characters.
public enum TextDiff {
    public struct Edit: Equatable, Sendable {
        public var deleteCount: Int
        public var insertion: String

        public init(deleteCount: Int, insertion: String) {
            self.deleteCount = deleteCount
            self.insertion = insertion
        }

        public var isEmpty: Bool { deleteCount == 0 && insertion.isEmpty }
    }

    public static func edit(from old: String, to new: String) -> Edit {
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, prefix < newChars.count, oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        return Edit(deleteCount: oldChars.count - prefix, insertion: String(newChars[prefix...]))
    }
}
