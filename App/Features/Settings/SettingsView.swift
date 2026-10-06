import RemoteCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.hapticsKey) private var haptics = true
    @AppStorage(AppSettings.sensitivityKey) private var sensitivity = 1.0
    @AppStorage(AppSettings.preferDPadKey) private var preferDPad = false
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppSettings.Appearance.dark

    var body: some View {
        Form {
            Section("Remote") {
                Toggle("Haptic Feedback", isOn: $haptics)
                Toggle("Use D-pad Instead of Touchpad", isOn: $preferDPad)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Touchpad Sensitivity")
                    HStack {
                        Image(systemName: "tortoise")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(value: $sensitivity, in: 0.5...2, step: 0.1)
                            .accessibilityLabel("Touchpad sensitivity")
                            .accessibilityValue(String(format: "%.1f", sensitivity))
                        Image(systemName: "hare")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppSettings.Appearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Section("TVs") {
                ForEach(model.store.devices) { device in
                    NavigationLink {
                        DeviceDetailView(deviceID: device.id)
                    } label: {
                        DeviceRow(device: device, isSaved: false)
                    }
                }
                Button {
                    model.isAddingTV = true
                } label: {
                    Label("Add a TV", systemImage: "plus")
                }
                NavigationLink {
                    ManualAddView()
                } label: {
                    Label("Add by IP Address", systemImage: "number")
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
            } footer: {
                Text("Remote is an independent app. It is not affiliated with, endorsed by, or sponsored by any TV or streaming-device maker. Product names are used only to describe compatibility.")
            }
        }
        .navigationTitle("Settings")
    }
}

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deviceID: String

    @State private var name = ""
    @State private var confirmingForget = false

    private var device: DeviceDescriptor? {
        model.store.devices.first { $0.id == deviceID }
    }

    var body: some View {
        Form {
            if let device {
                Section("Name") {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit { model.rename(device.id, to: name) }
                }
                Section("Details") {
                    LabeledContent("Type", value: device.platform.displayName)
                    LabeledContent("IP Address", value: device.host)
                    if let mac = device.mac {
                        LabeledContent("MAC Address", value: mac.uppercased())
                    }
                    if let modelName = device.model {
                        LabeledContent("Model", value: modelName)
                    }
                }
                Section {
                    if device.platform.pairingStyle != .none {
                        Button("Pair Again") { model.repair(device) }
                    }
                    Button("Forget This TV", role: .destructive) { confirmingForget = true }
                } footer: {
                    if device.platform.pairingStyle != .none {
                        Text("Pair again if the TV was reset or stopped responding to this phone.")
                    }
                }
            }
        }
        .navigationTitle(device?.name ?? "TV")
        .onAppear { name = device?.name ?? "" }
        .onDisappear {
            if let device, name != device.name { model.rename(device.id, to: name) }
        }
        .confirmationDialog("Forget \(device?.name ?? "this TV")?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                model.forget(deviceID)
                dismiss()
            }
        } message: {
            Text("You'll need to pair again to use it.")
        }
    }
}

extension Bundle {
    var versionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
