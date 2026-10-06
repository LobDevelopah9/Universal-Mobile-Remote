import RemoteCore
import RemoteDrivers
import SwiftUI

/// "Find your TV": a live list of TVs on the Wi-Fi. Tapping one pairs or connects.
struct FindTVView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if model.snapshot.localNetworkDenied {
                Section {
                    LocalNetworkHint { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                }
            }

            Section {
                if model.discoveredDevices.isEmpty {
                    SearchingRow(isScanning: model.snapshot.isScanning)
                }
                ForEach(model.discoveredDevices) { device in
                    Button { model.select(device) } label: {
                        DeviceRow(device: device, isSaved: model.isSaved(device))
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("TVs on your Wi-Fi")
                    if model.snapshot.isScanning && !model.discoveredDevices.isEmpty {
                        ProgressView().controlSize(.small)
                    }
                }
            } footer: {
                Text("Your TV must be turned on and connected to the same Wi-Fi as this iPhone. Pull down to search again.")
            }

            if !model.unsupportedDevices.isEmpty {
                Section("Coming in a later update") {
                    ForEach(model.unsupportedDevices) { device in
                        DeviceRow(device: device, isSaved: false)
                            .opacity(0.5)
                    }
                }
            }

            Section {
                NavigationLink {
                    ManualAddView()
                } label: {
                    Label("Add by IP address", systemImage: "number")
                }
            }

            if AppSettings.demoEnabled {
                Section {
                    Button { model.select(MockTVDriver.demoDevice) } label: {
                        DeviceRow(device: MockTVDriver.demoDevice, isSaved: model.isSaved(MockTVDriver.demoDevice))
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Try it without a TV")
                }
            }
        }
        .navigationTitle("Find your TV")
        .refreshable { await model.rescan() }
        .onAppear { model.beginDiscovery() }
        .onDisappear { model.endDiscovery() }
        .animation(.default, value: model.discoveredDevices)
    }
}

private struct SearchingRow: View {
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 14) {
            if isScanning {
                ProgressView()
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(isScanning ? "Looking for TVs…" : "No TVs found yet")
                    .font(.body)
                if !isScanning {
                    Text("Check the TV is on, or add it by IP address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct LocalNetworkHint: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local Network access is off", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(DriverError.localNetworkDenied.recoverySuggestion ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }
}

struct DeviceRow: View {
    let device: DeviceDescriptor
    let isSaved: Bool

    var body: some View {
        HStack(spacing: 14) {
            PlatformGlyph(platform: device.platform)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSaved {
                Text("Paired")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(isSaved ? "Connects to this TV" : "Pairs with this TV")
    }

    private var subtitle: String {
        device.platform == .demo ? "Simulated, no TV needed" : "\(device.platform.displayName) · \(device.host)"
    }
}

struct PlatformGlyph: View {
    let platform: TVPlatform
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Image(systemName: platform.symbolName)
            .font(.system(size: size * 0.45, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}
