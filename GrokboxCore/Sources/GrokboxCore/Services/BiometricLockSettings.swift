import Foundation

/// Whether Grokbox requires Face ID/Touch ID (or the device passcode) before
/// showing any mail. Off unless the person using Grokbox turns it on in
/// Settings — see `BiometricAuthenticator`.
public struct BiometricLockSettings: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public static let disabled = BiometricLockSettings(enabled: false)

    // MARK: - Persistence

    static let defaultsKey = "grokbox.biometricLockSettings"

    /// The setting in force. Defaults to off for anyone who never opens Settings.
    public static var current: BiometricLockSettings {
        get { load() }
        set { save(newValue) }
    }

    public static func load(from defaults: UserDefaults = .standard) -> BiometricLockSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(BiometricLockSettings.self, from: data) else { return .disabled }
        return settings
    }

    public static func save(_ settings: BiometricLockSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
