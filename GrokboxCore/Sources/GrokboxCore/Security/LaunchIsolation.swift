import Foundation

/// Demo-only mode: a build or launch that can only touch built-in demo mail.
///
/// A process is demo-only when its bundle identifier is
/// `isolatedBundleIdentifier` (the isolation build, on by construction, so a
/// Shortcuts, Login Items or `open` launch cannot reach real data) or when it
/// was started with `--isolated-demo`. The decision is made once, on first
/// read, and nothing in the process can turn it off.
///
/// Every surface that could reach real data asks `refuse(_:)` first: the
/// Keychain, mail servers, unsubscribe requests and account autoconfiguration.
public enum LaunchIsolation {
    public static let isolatedBundleIdentifier = "com.wesleykeetch.grokbox.isolation"
    public static let switchArgument = "--isolated-demo"
    public static let defaultsSuiteName = "com.wesleykeetch.grokbox.isolated-demo"
    public static let logSubsystem = "com.wesleykeetch.grokbox.isolated-demo"

    /// Tests set this for the duration of one task, so a test can run in
    /// demo-only mode without changing what concurrently running tests see.
    @TaskLocal public static var override: Bool?

    /// A test override can only switch isolation on, never clear the process's own decision.
    public static var isDemoOnly: Bool { processWide || override == true }

    private static let processWide = requested(bundleIdentifier: Bundle.main.bundleIdentifier,
                                               arguments: CommandLine.arguments)

    public static func requested(bundleIdentifier: String?, arguments: [String]) -> Bool {
        bundleIdentifier == isolatedBundleIdentifier || arguments.contains(switchArgument)
    }

    // MARK: - Refusals

    public enum Surface: String, Sendable, CaseIterable {
        case keychain = "the Keychain"
        case mailServer = "a mail server"
        case unsubscribe = "unsubscribe requests"
        case autoconfig = "account autoconfiguration"
        case modelBackend = "a model backend"
        case notifications = "notifications"
    }

    public struct Refusal: LocalizedError, Equatable, Sendable {
        public let surface: Surface

        public init(surface: Surface) { self.surface = surface }

        public var errorDescription: String? {
            "Demo-only mode: Grokbox will not use \(surface.rawValue). This build works only on its built-in demo mailboxes."
        }
    }

    public static func refuse(_ surface: Surface) throws {
        if isDemoOnly { throw Refusal(surface: surface) }
    }

    // MARK: - Launch arguments

    private static let refusedFlags: Set<String> = ["--reset", "--run-all", "--catch-up", "--selftest"]
    private static let refusedFlagsWithValue: Set<String> = ["--index", "--read"]
    private static let forcedFlags = ["--demo", "--stub-model"]

    /// The launch arguments the app should act on. Outside demo-only mode they
    /// are returned unchanged. In it, the flags that erase data, tidy up real
    /// accounts, read real mailboxes or open the Keychain are dropped, and the
    /// demo mailboxes and the rules-only reader are forced on.
    public static func effectiveArguments(_ arguments: [String], demoOnly: Bool) -> [String] {
        guard demoOnly else { return arguments }
        var kept: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            if index == arguments.startIndex + 1 { kept.append(argument); continue }
            if refusedFlags.contains(argument) { continue }
            if refusedFlagsWithValue.contains(argument) {
                if index < arguments.endIndex, !arguments[index].hasPrefix("--") { index += 1 }
                continue
            }
            kept.append(argument)
        }
        for flag in forcedFlags where !kept.contains(flag) { kept.append(flag) }
        return kept
    }

    // MARK: - Attestation

    /// What this process will and will not do, one `key=value` per line,
    /// written to the log before any scene exists so a run can check it.
    public static func attestation(bundleIdentifier: String?, storeConfiguration: String, logPath: String) -> [String] {
        func state(_ surface: Surface) -> String {
            do { try refuse(surface); return "open" } catch { return "refused" }
        }
        return [
            "demoOnly=\(isDemoOnly)",
            "bundleID=\(bundleIdentifier ?? "none")",
            "store=\(storeConfiguration)",
            "defaults=\(GrokboxDefaults.store === UserDefaults.standard ? "standard" : defaultsSuiteName)",
            "logPath=\(logPath)",
            "logSubsystem=\(isDemoOnly ? logSubsystem : "com.wesleykeetch.grokbox")",
            "keychain=\(state(.keychain))",
            "mailServer=\(state(.mailServer))",
            "unsubscribe=\(state(.unsubscribe))",
            "autoconfig=\(state(.autoconfig))",
            "modelBackend=\(state(.modelBackend))",
            "notifications=\(state(.notifications))",
        ]
    }
}
