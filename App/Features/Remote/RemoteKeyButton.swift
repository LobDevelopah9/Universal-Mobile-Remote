import RemoteCore
import SwiftUI

/// How a remote button behaves while held.
enum HoldBehavior {
    /// Fires once on touch-down. Feels instant.
    case tap
    /// Fires on touch-down, then repeats every 90 ms after 400 ms (arrows, volume).
    case autoRepeat
    /// A short tap fires on release; holding sends a native long press if the TV
    /// supports key-down/up (OK, Home), otherwise it's just a tap.
    case longPress
}

/// A round remote button that reacts on touch-down, not on release.
struct RemoteKeyButton: View {
    let key: RemoteKey
    let systemImage: String
    var behavior: HoldBehavior = .tap
    var diameter: CGFloat = 64
    var prominent = false
    let session: RemoteViewModel

    @State private var isPressed = false
    @State private var holdTask: Task<Void, Never>?
    @State private var didHold = false
    @ScaledMetric(relativeTo: .title2) private var scale: CGFloat = 1

    private static let holdDelay: Duration = .milliseconds(400)
    private static let repeatInterval: Duration = .milliseconds(90)

    var body: some View {
        let size = diameter * min(scale, 1.4)
        face(size: size)
            .scaleEffect(isPressed ? 0.9 : 1)
            .brightness(isPressed ? 0.12 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: isPressed)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed { touchDown() }
                    }
                    .onEnded { _ in touchUp() }
            )
            .accessibilityElement()
            .accessibilityLabel(key.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.press(key) }
    }

    private func face(size: CGFloat) -> some View {
        let fill: Color = prominent ? .accentColor : .remoteKey
        let ink: Color = prominent ? .white : .primary
        let rim = Color.white.opacity(isPressed ? 0.25 : 0.06)
        return Image(systemName: systemImage)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(rim, lineWidth: 1))
    }

    private func touchDown() {
        isPressed = true
        didHold = false
        switch behavior {
        case .tap:
            session.press(key)
        case .autoRepeat:
            session.press(key)
            holdTask = Task {
                try? await Task.sleep(for: Self.holdDelay)
                while !Task.isCancelled {
                    session.repeatPress(key)
                    try? await Task.sleep(for: Self.repeatInterval)
                }
            }
        case .longPress:
            Haptics.press()
            holdTask = Task {
                try? await Task.sleep(for: Self.holdDelay)
                guard !Task.isCancelled, session.supportsKeyHold else { return }
                didHold = true
                session.holdBegan(key)
            }
        }
    }

    private func touchUp() {
        isPressed = false
        holdTask?.cancel()
        holdTask = nil
        guard behavior == .longPress else { return }
        if didHold {
            session.holdEnded(key)
        } else {
            session.repeatPress(key) // haptic already fired on touch-down
        }
    }
}

extension Color {
    /// Raised key surface. Slightly lighter than the background in dark mode.
    static let remoteKey = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.17, alpha: 1)
            : UIColor(white: 0.9, alpha: 1)
    })

    static let remoteSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.11, alpha: 1)
            : UIColor(white: 0.95, alpha: 1)
    })
}
