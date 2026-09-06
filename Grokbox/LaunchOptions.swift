import Foundation
import GrokboxCore

/// Command-line switches for putting the app into a known state. Used to
/// screenshot and audit screens without clicking through them.
///
///     Grokbox --demo              add the three sample mailboxes
///     Grokbox --run-all           tidy up every account (index, rules, read)
///     Grokbox --section brief     open on a section (brief|senders|sweep|activity|settings)
///     Grokbox --account 1         select the Nth account (0-based); "all" for the cross-account Brief
///     Grokbox --reset             erase all local data first
///     Grokbox --demo-sweep        apply the suggested sweep on DEMO accounts only (never real ones)
///     Grokbox --demo-undo         undo the newest archive action on each DEMO account
///     Grokbox --catch-up          read older mail (last year) from people and record-keepers
///     Grokbox --selftest          prove the sandbox can do the things a real account needs
struct LaunchOptions {
    var addDemo = false
    var runAll = false
    var reset = false
    var demoSweep = false
    var demoUndo = false
    var catchUp = false
    var selftest = false
    /// Diagnostic: render only part of the UI. bare | sidebar | detail | full (default).
    var ui = "full"
    /// Diagnostic: menu-bar content variant. text | query | state | full (default).
    var menuBar = "full"
    /// Diagnostic: scene composition. no-menubar | plain | state-binding | full (default).
    var scene = "full"
    var section: AppSection?
    var account: String?

    static let current: LaunchOptions = {
        var options = LaunchOptions()
        let args = CommandLine.arguments
        options.addDemo = args.contains("--demo")
        options.runAll = args.contains("--run-all")
        options.reset = args.contains("--reset")
        options.demoSweep = args.contains("--demo-sweep")
        options.demoUndo = args.contains("--demo-undo")
        options.catchUp = args.contains("--catch-up")
        options.selftest = args.contains("--selftest")
        if let i = args.firstIndex(of: "--ui"), i + 1 < args.count { options.ui = args[i + 1] }
        if let i = args.firstIndex(of: "--mb"), i + 1 < args.count { options.menuBar = args[i + 1] }
        if let i = args.firstIndex(of: "--scene"), i + 1 < args.count { options.scene = args[i + 1] }
        if let i = args.firstIndex(of: "--section"), i + 1 < args.count {
            options.section = AppSection(rawValue: args[i + 1])
        }
        if let i = args.firstIndex(of: "--account"), i + 1 < args.count {
            options.account = args[i + 1]
        }
        return options
    }()
}
