import Observation
import RemoteCore
import RemoteDrivers
import SwiftUI

@MainActor
@Observable
final class PairingViewModel {
    enum Step: Equatable {
        case connecting
        case enterCode
        case verifying
        case waitingForAccept
        case failed(DriverError)
        case done
    }

    let device: DeviceDescriptor
    private(set) var step: Step = .connecting
    private(set) var codeError: String?
    @ObservationIgnored private var driver: (any TVDriver)?
    /// Called once the TV is paired and connected.
    @ObservationIgnored var onPaired: ((any TVDriver, PairingCredentials) -> Void)?

    init(device: DeviceDescriptor) {
        self.device = device
    }

    var codeLength: Int {
        if case .codeOnTV(let length, _) = device.platform.pairingStyle { return length }
        return 0
    }

    var codeAlphabet: PairingStyle.CodeAlphabet {
        if case .codeOnTV(_, let alphabet) = device.platform.pairingStyle { return alphabet }
        return .numeric
    }

    func start() async {
        codeError = nil
        // Pairing always uses a fresh driver with no stored credentials.
        guard let driver = DriverFactory.make(for: device, credentials: nil) else {
            step = .failed(.unsupported("this kind of TV yet"))
            return
        }
        self.driver = driver
        switch device.platform.pairingStyle {
        case .automatic:
            step = .connecting
            await finish(code: nil)
        case .codeOnTV:
            step = .connecting
            do {
                try await driver.startPairing()
                step = .enterCode
            } catch {
                fail(error)
            }
        case .acceptOnTV:
            step = .waitingForAccept
            await finish(code: nil)
        }
    }

    func submit(code: String) async {
        guard step == .enterCode else { return }
        step = .verifying
        await finish(code: code)
    }

    func cancel() {
        let driver = driver
        Task { await driver?.disconnect() }
    }

    private func finish(code: String?) async {
        guard let driver else { return }
        do {
            let credentials = try await driver.pair(code: code)
            step = .done
            Haptics.success()
            onPaired?(driver, credentials)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        let driverError = DriverError(error)
        Haptics.error()
        // A typo keeps the TV's pairing session open, so let the user retype.
        if driverError == .pairingCodeMismatch, codeLength > 0 {
            codeError = driverError.userMessage
            step = .enterCode
            return
        }
        step = .failed(driverError)
    }
}

/// Platform-specific pairing: nothing (Roku), a code shown on the TV (Android TV),
/// or an allow prompt on the TV (later platforms).
struct PairingFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: PairingViewModel

    init(device: DeviceDescriptor) {
        _pairing = State(initialValue: PairingViewModel(device: device))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .navigationTitle(pairing.device.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            pairing.cancel()
                            dismiss()
                        }
                    }
                }
                .animation(.snappy, value: pairing.step)
        }
        .interactiveDismissDisabled(pairing.step == .verifying)
        .task {
            let device = pairing.device
            pairing.onPaired = { [model] driver, credentials in
                model.completePairing(device: device, driver: driver, credentials: credentials)
            }
            await pairing.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pairing.step {
        case .connecting:
            ProgressStep(title: "Connecting to \(pairing.device.name)…", systemImage: pairing.device.platform.symbolName)
        case .enterCode:
            CodeEntryStep(
                length: pairing.codeLength,
                alphabet: pairing.codeAlphabet,
                error: pairing.codeError
            ) { code in
                Task { await pairing.submit(code: code) }
            }
        case .verifying:
            ProgressStep(title: "Pairing…", systemImage: "lock.shield")
        case .waitingForAccept:
            ProgressStep(title: "Accept the prompt on your TV", systemImage: "hand.tap")
        case .failed(let error):
            FailedStep(error: error) {
                Task { await pairing.start() }
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .accessibilityLabel("Paired")
        }
    }
}

private struct ProgressStep: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            ProgressView()
        }
    }
}

private struct FailedStep: View {
    let error: DriverError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(error.userMessage)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
    }
}

/// One box per character, backed by a single hidden text field.
private struct CodeEntryStep: View {
    let length: Int
    let alphabet: PairingStyle.CodeAlphabet
    let error: String?
    let submit: (String) -> Void

    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Enter the code shown on your TV")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(alphabet == .hexadecimal ? "It uses the digits 0–9 and letters A–F." : "It's a \(length)-digit number.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                TextField("", text: $code)
                    .keyboardType(alphabet == .numeric ? .numberPad : .asciiCapable)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.02)
                    .accessibilityLabel("Pairing code")
                    .accessibilityValue(code)

                HStack(spacing: 8) {
                    ForEach(0..<length, id: \.self) { index in
                        CodeBox(character: character(at: index), isActive: focused && index == code.count)
                    }
                }
                .accessibilityHidden(true)
                .onTapGesture { focused = true }
            }

            if let error {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .onAppear { focused = true }
        .onChange(of: code) { _, newValue in
            let filtered = String(newValue.uppercased().filter(alphabet.accepts).prefix(length))
            if filtered != newValue {
                code = filtered
                return
            }
            if filtered.count == length {
                submit(filtered)
            }
        }
        .onChange(of: error) { _, newError in
            if newError != nil { code = "" }
        }
    }

    private func character(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }
}

private struct CodeBox: View {
    let character: String
    let isActive: Bool
    @ScaledMetric(relativeTo: .title) private var width: CGFloat = 44

    var body: some View {
        Text(character)
            .font(.system(.title, design: .monospaced).weight(.semibold))
            .frame(width: width, height: width * 1.25)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            }
    }
}
