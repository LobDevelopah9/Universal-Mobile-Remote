import SwiftUI

/// UserDefaults keys and defaults for user preferences. Views read them with `@AppStorage`.
enum AppSettings {
    static let hapticsKey = "haptics"
    static let sensitivityKey = "touchpadSensitivity"
    static let preferDPadKey = "preferDPad"
    static let appearanceKey = "appearance"

    enum Appearance: String, CaseIterable, Identifiable {
        case dark, light, system
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dark: "Dark"
            case .light: "Light"
            case .system: "Match System"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .dark: .dark
            case .light: .light
            case .system: nil
            }
        }
    }

    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true
    }

    static var touchpadSensitivity: Double {
        UserDefaults.standard.object(forKey: sensitivityKey) as? Double ?? 1
    }

    /// The Demo TV shows up in simulator and debug builds, or when launched with `-mockTV`.
    static var demoEnabled: Bool {
        #if DEBUG || targetEnvironment(simulator)
        true
        #else
        ProcessInfo.processInfo.arguments.contains("-mockTV")
        #endif
    }

    /// Set from the ENABLE_MULTICAST build setting via Info.plist.
    static var multicastEnabled: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "RMMulticastEnabled") as? String
        return value?.uppercased() == "YES"
    }
}

@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    static func prepare() {
        guard AppSettings.hapticsEnabled else { return }
        light.prepare()
        selection.prepare()
    }

    /// A button press.
    static func press() {
        guard AppSettings.hapticsEnabled else { return }
        light.impactOccurred()
    }

    /// One step of touchpad movement.
    static func tick() {
        guard AppSettings.hapticsEnabled else { return }
        selection.selectionChanged()
    }

    /// A long press turning into a hold.
    static func hold() {
        guard AppSettings.hapticsEnabled else { return }
        rigid.impactOccurred(intensity: 0.7)
    }

    static func success() {
        guard AppSettings.hapticsEnabled else { return }
        notification.notificationOccurred(.success)
    }

    static func error() {
        guard AppSettings.hapticsEnabled else { return }
        notification.notificationOccurred(.error)
    }
}
