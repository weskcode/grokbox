import Foundation

/// Where Grokbox keeps its settings. `.standard` normally. In demo-only mode a
/// separate suite, cleared the first time it is used, so nothing is read from
/// or written to the real app's preferences.
///
/// A `UserDefaults` suite still searches the argument and registration
/// domains: this separates the persistent domain only.
public enum GrokboxDefaults {
    public static var store: UserDefaults {
        LaunchIsolation.isDemoOnly ? isolated : .standard
    }

    // UserDefaults is documented as safe to use from any thread.
    private nonisolated(unsafe) static let isolated: UserDefaults = {
        UserDefaults.standard.removePersistentDomain(forName: LaunchIsolation.defaultsSuiteName)
        guard let suite = UserDefaults(suiteName: LaunchIsolation.defaultsSuiteName) else {
            preconditionFailure("Demo-only mode could not create its own defaults; refusing to fall back to the real ones.")
        }
        return suite
    }()
}
