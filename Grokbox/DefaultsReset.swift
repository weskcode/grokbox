import Foundation
import GrokboxCore

/// The UserDefaults keys Grokbox writes, and how to put them back. Kept in one
/// place so "erase everything" cannot drift out of date as settings are added.
enum MailboxSnapshotDefaults {
    static let keys = [
        "grokbox.cleanupPolicy", "grokbox.preferredModel", "grokbox.ollamaModel",
        "grokbox.autoMaintain", "grokbox.autoIntervalMinutes", "grokbox.readLimit",
        "grokbox.indexDepth", "grokbox.notify", "grokbox.guardTransactional",
    ]

    static func reset(_ defaults: UserDefaults = .standard) {
        for key in keys { defaults.removeObject(forKey: key) }
    }
}
