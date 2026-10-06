import RemoteCore
import SwiftUI

/// Swipe to move, tap to select. On TVs without native touch input the drag is
/// turned into D-pad presses, one per step, with a haptic tick for each.
struct TouchpadView: View {
    let session: RemoteViewModel

    @State private var touchLocation: CGPoint?
    @State private var touchStart: Date?

    private static let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)

    var body: some View {
        surface
            .contentShape(Self.shape)
            .gesture(drag)
            .accessibilityElement()
            .accessibilityLabel("Touchpad")
            .accessibilityHint("Double-tap to select. Use the actions rotor to move.")
            .accessibilityAction { session.press(.select) }
            .accessibilityAction(named: "Up") { session.press(.up) }
            .accessibilityAction(named: "Down") { session.press(.down) }
            .accessibilityAction(named: "Left") { session.press(.left) }
            .accessibilityAction(named: "Right") { session.press(.right) }
    }

    private var surface: some View {
        Self.shape
            .fill(Color.remoteSurface)
            .overlay { Self.shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 1) }
            .overlay { touchIndicator }
    }

    @ViewBuilder
    private var touchIndicator: some View {
        if let touchLocation {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: 84, height: 84)
                .blur(radius: 6)
                .position(touchLocation)
                .transition(.opacity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "hand.draw")
                    .font(.title2)
                Text("Swipe to move · Tap to select")
                    .font(.footnote)
            }
            .foregroundStyle(.tertiary)
            .allowsHitTesting(false)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if touchStart == nil {
                    touchStart = .now
                    session.touchpadBegan()
                }
                touchLocation = value.location
                session.touchpadMoved(value.translation)
            }
            .onEnded { value in
                let duration = Date.now.timeIntervalSince(touchStart ?? .now)
                session.touchpadEnded(value.translation, duration: duration)
                touchStart = nil
                withAnimation(.easeOut(duration: 0.25)) { touchLocation = nil }
            }
    }
}

/// The classic ring: four arrows around an OK button.
struct DPadView: View {
    let session: RemoteViewModel

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let arrow = side * 0.24
            let offset = side * 0.33
            ZStack {
                Circle()
                    .fill(Color.remoteSurface)
                    .overlay { Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1) }
                RemoteKeyButton(key: .up, systemImage: "chevron.up", behavior: .autoRepeat, diameter: arrow, session: session)
                    .offset(y: -offset)
                RemoteKeyButton(key: .down, systemImage: "chevron.down", behavior: .autoRepeat, diameter: arrow, session: session)
                    .offset(y: offset)
                RemoteKeyButton(key: .left, systemImage: "chevron.left", behavior: .autoRepeat, diameter: arrow, session: session)
                    .offset(x: -offset)
                RemoteKeyButton(key: .right, systemImage: "chevron.right", behavior: .autoRepeat, diameter: arrow, session: session)
                    .offset(x: offset)
                RemoteKeyButton(key: .select, systemImage: "circle.fill", behavior: .longPress, diameter: side * 0.34, prominent: true, session: session)
                    .accessibilityLabel("OK")
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
