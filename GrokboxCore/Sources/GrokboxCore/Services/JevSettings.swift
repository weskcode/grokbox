import Foundation

/// Whether the opt-in Jev cloud fallback is turned on. Off unless the person
/// using Grokbox turns it on in Settings — see ADR-0023 and docs/PRIVACY.md.
///
/// The API key itself is never in here: it lives in `JevKeyStore`, not
/// `UserDefaults`. This struct only ever holds the non-secret preference.
public struct JevSettings: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public static let disabled = JevSettings(enabled: false)

    // MARK: - Persistence

    static let defaultsKey = "grokbox.jevSettings"

    /// The setting in force. Defaults to off for anyone who never opens Settings.
    public static var current: JevSettings {
        get { load() }
        set { save(newValue) }
    }

    public static func load(from defaults: UserDefaults = .standard) -> JevSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(JevSettings.self, from: data) else { return .disabled }
        return settings
    }

    public static func save(_ settings: JevSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
