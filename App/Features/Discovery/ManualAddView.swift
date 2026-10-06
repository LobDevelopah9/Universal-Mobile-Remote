import RemoteCore
import SwiftUI

/// Fallback when discovery can't see the TV: type its IP address.
struct ManualAddView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var isProbing = false
    @State private var results: [DeviceDescriptor]?
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.20", text: $address)
                    .keyboardType(.decimalPad)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .font(.body.monospacedDigit())
                    .accessibilityLabel("TV IP address")
                Button {
                    Task { await probe() }
                } label: {
                    HStack {
                        Text("Find TV")
                        if isProbing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!isValidAddress || isProbing)
            } header: {
                Text("IP address")
            } footer: {
                Text("You can find it in your TV's network settings, usually under Settings → Network → About or Status.")
            }

            if let results {
                Section("Result") {
                    if results.isEmpty {
                        Label("No supported TV answered at \(address).", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { device in
                        Button { model.select(device) } label: {
                            DeviceRow(device: device, isSaved: model.isSaved(device))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Add by IP Address")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private var isValidAddress: Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private func probe() async {
        focused = false
        isProbing = true
        results = await model.probe(host: address)
        isProbing = false
    }
}
