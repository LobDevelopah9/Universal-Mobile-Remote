import RemoteCore
import SwiftUI

struct RemoteView: View {
    let session: RemoteViewModel

    @AppStorage(AppSettings.preferDPadKey) private var preferDPad = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isTyping = false

    var body: some View {
        VStack(spacing: 14) {
            DeviceSwitcherPill(session: session)
            StatusBanner(session: session)

            let landscape = verticalSizeClass == .compact
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 20))
            layout {
                navigationSurface
                    .frame(maxWidth: landscape ? 360 : .infinity, maxHeight: .infinity)
                ControlPanel(session: session, isTyping: $isTyping)
                    .frame(maxWidth: 420)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .sheet(isPresented: $isTyping) {
            KeyboardSheet(session: session)
                .presentationDetents([.height(170)])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var navigationSurface: some View {
        ZStack(alignment: .topTrailing) {
            if preferDPad {
                DPadView(session: session)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                TouchpadView(session: session)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            Button {
                withAnimation(.snappy) { preferDPad.toggle() }
            } label: {
                Image(systemName: preferDPad ? "hand.draw" : "dpad")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(10)
            .accessibilityLabel(preferDPad ? "Switch to touchpad" : "Switch to D-pad")
        }
    }
}

/// Back / Home / Play-Pause, then volume, power and keyboard. Only what the TV supports.
struct ControlPanel: View {
    let session: RemoteViewModel
    @Binding var isTyping: Bool

    private var caps: TVCapabilities { session.capabilities }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                slot { RemoteKeyButton(key: .back, systemImage: "arrow.uturn.backward", session: session) }
                slot { RemoteKeyButton(key: .home, systemImage: "house.fill", behavior: .longPress, session: session) }
                if caps.contains(.mediaControls) {
                    slot { RemoteKeyButton(key: .playPause, systemImage: "playpause.fill", session: session) }
                }
                if caps.contains(.keyboard) {
                    slot {
                        CircleButton(systemImage: "keyboard", label: "Keyboard") { isTyping = true }
                    }
                }
            }

            if caps.contains(.mediaControls) {
                HStack(spacing: 0) {
                    slot { RemoteKeyButton(key: .rewind, systemImage: "backward.fill", behavior: .autoRepeat, diameter: 52, session: session) }
                    slot { RemoteKeyButton(key: .menu, systemImage: "line.3.horizontal", diameter: 52, session: session) }
                    slot { RemoteKeyButton(key: .fastForward, systemImage: "forward.fill", behavior: .autoRepeat, diameter: 52, session: session) }
                }
            }

            if caps.contains(.volume) || caps.contains(.power) {
                HStack(spacing: 0) {
                    if caps.contains(.volume) {
                        slot { RemoteKeyButton(key: .volumeDown, systemImage: "speaker.minus.fill", behavior: .autoRepeat, diameter: 52, session: session) }
                        if caps.contains(.mute) {
                            slot { RemoteKeyButton(key: .mute, systemImage: "speaker.slash.fill", diameter: 52, session: session) }
                        }
                        slot { RemoteKeyButton(key: .volumeUp, systemImage: "speaker.plus.fill", behavior: .autoRepeat, diameter: 52, session: session) }
                    }
                    if caps.contains(.power) {
                        slot { PowerButton(session: session) }
                    }
                }
            }
        }
        .animation(.default, value: caps)
    }

    private func slot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity)
    }
}

/// Power is red and needs a deliberate press, so it's easy to find and hard to hit by accident.
private struct PowerButton: View {
    let session: RemoteViewModel

    var body: some View {
        Button { session.press(.power) } label: {
            Image(systemName: "power")
                .font(.system(size: 18, weight: .bold))
                .frame(width: 52, height: 52)
                .foregroundStyle(.white)
                .background(Color.red.opacity(0.85), in: Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Power")
    }
}

struct CircleButton: View {
    let systemImage: String
    let label: String
    var diameter: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.32, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .background(Color.remoteKey, in: Circle())
        }
        .buttonStyle(PressScaleStyle())
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Shows "Reconnecting…" quietly, and problems the user must fix loudly, with the fix.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    let session: RemoteViewModel

    var body: some View {
        Group {
            if let alert = session.alert {
                VStack(alignment: .leading, spacing: 8) {
                    Label(alert.userMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                    if let suggestion = alert.recoverySuggestion {
                        Text(suggestion)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        if alert == .pairingRequired {
                            Button("Re-pair") { model.repair(session.device) }
                        } else {
                            Button("Try Again") { session.reconnect() }
                        }
                        Spacer()
                        Button("Dismiss") { session.alert = nil }
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if session.isReconnecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(session.state == .connecting ? "Connecting…" : "Reconnecting…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.snappy, value: session.alert)
        .animation(.snappy, value: session.isReconnecting)
    }
}

/// The TV name at the top; tap to switch between saved TVs or add one.
struct DeviceSwitcherPill: View {
    @Environment(AppModel.self) private var model
    let session: RemoteViewModel

    var body: some View {
        Menu {
            ForEach(model.store.devices) { device in
                Button {
                    model.activate(device)
                } label: {
                    if device.id == session.device.id {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Label(device.name, systemImage: device.platform.symbolName)
                    }
                }
            }
            Divider()
            Button {
                model.isAddingTV = true
            } label: {
                Label("Add a TV…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(session.device.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("\(session.device.name), \(statusText)")
        .accessibilityHint("Switch to another TV")
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .error(let error) where !error.isTransient: .red
        default: .orange
        }
    }

    private var statusText: String {
        switch session.state {
        case .connected: "connected"
        case .error(let error) where !error.isTransient: "not connected"
        default: "connecting"
        }
    }
}

/// Characters stream to the TV as you type.
struct KeyboardSheet: View {
    let session: RemoteViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Type on your TV")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
            HStack(spacing: 10) {
                TextField("Search or type", text: $text)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit {
                        session.submitTyping()
                        focused = true
                    }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.title3)
                    }
                    .accessibilityLabel("Clear text on TV")
                }
            }
        }
        .padding(20)
        .onAppear {
            session.beginTyping()
            focused = true
        }
        .onChange(of: text) { _, newValue in
            session.typingChanged(to: newValue)
        }
    }
}
