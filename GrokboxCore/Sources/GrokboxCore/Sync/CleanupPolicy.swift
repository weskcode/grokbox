import Foundation

/// How aggressively Grokbox cleans, and what "clean" means to this person.
///
/// Everything here is a *user* decision, not a heuristic. The defaults are the
/// safest reading of the project's rule: never destroy anything, always be
/// undoable, always explain. Turning the dial up is allowed; doing it silently
/// is not, which is why every field has a sentence attached (`summary`).
public struct CleanupPolicy: Codable, Sendable, Equatable {

    /// What happens to a message that is swept.
    public enum Disposition: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Out of the inbox and into `Grokbox/<Kind>` — the default. Findable
        /// by folder, and undoable.
        case fileIntoFolders
        /// Out of the inbox, no folder. Gmail's Archive; a plain server's
        /// Archive mailbox.
        case archiveOnly
        /// Into the server's Trash. Recoverable until the provider empties it
        /// on its own schedule — Grokbox never expunges.
        case trash

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .fileIntoFolders: "File into folders"
            case .archiveOnly: "Archive only"
            case .trash: "Move to Trash"
            }
        }

        public var explanation: String {
            switch self {
            case .fileIntoFolders:
                "Swept mail goes to Grokbox/Promotions, Grokbox/Newsletters and so on. Nothing is deleted, and everything stays findable by folder."
            case .archiveOnly:
                "Swept mail leaves the inbox but is not filed. It stays in All Mail (Gmail) or Archive, findable by search."
            case .trash:
                "Swept mail goes to your provider's Trash, which they empty on their own schedule — typically 30 days. Grokbox never empties it and never expunges, so you can move anything back until then."
            }
        }

        /// Trash is the one setting that can end in real data loss, by the
        /// provider's hand rather than Grokbox's. Say so where it is chosen.
        public var warning: String? {
            self == .trash ? "Your provider will delete this mail permanently when it empties the Trash. Undo works until then." : nil
        }
    }

    /// Whether Grokbox may press Unsubscribe on your behalf.
    public enum UnsubscribeMode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Never automatically. The button in Senders still works.
        case never
        /// Only for senders that clearly qualify, and only via the sender's
        /// own RFC 8058 one-click endpoint.
        case automaticOneClick
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .never: "Only when I press it"
            case .automaticOneClick: "Automatically, when a sender qualifies"
            }
        }
    }

    /// Named starting points. Each is a complete policy; the user can adjust
    /// any field afterwards and the preset becomes "Custom".
    public enum Preset: String, Codable, Sendable, CaseIterable, Identifiable {
        case gentle, balanced, thorough, custom
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .gentle: "Gentle"
            case .balanced: "Balanced"
            case .thorough: "Thorough"
            case .custom: "Custom"
            }
        }

        public var blurb: String {
            switch self {
            case .gentle: "Files bulk mail into folders. Keeps the last two from every sender and anything from the past week. Never unsubscribes for you."
            case .balanced: "Files bulk mail into folders, keeps the newest from each sender, and unsubscribes from senders you have never written to and never open."
            case .thorough: "Trashes promotions you never open, files the rest, and unsubscribes wherever a one-click link exists."
            case .custom: "Your own settings."
            }
        }
    }

    // MARK: - Fields

    public var disposition: Disposition
    /// Promotions can be treated differently from everything else — most
    /// people want marketing gone but newsletters filed.
    public var promotionDisposition: Disposition?
    public var unsubscribe: UnsubscribeMode
    public var markRead: Bool

    /// Never sweep anything newer than this many days. 0 turns it off.
    public var protectRecentDays: Int
    /// Always keep this many of the newest messages from each sender. 0 = off.
    public var keepNewestPerSender: Int

    /// Hold receipts, orders, appointments and security mail out of sweeps.
    public var guardTransactional: Bool
    /// Never sweep a sender you have written to, whatever the verdict says.
    public var guardContacted: Bool

    // Conditions for automatic unsubscribe, all of which must hold.
    /// e.g. 0.9 = at least 90% of their mail unread.
    public var autoUnsubscribeMinimumUnreadRatio: Double
    public var autoUnsubscribeMinimumMessages: Int
    public var autoUnsubscribeRequiresNeverContacted: Bool

    // MARK: - Presets

    public static let gentle = CleanupPolicy(
        disposition: .fileIntoFolders, promotionDisposition: nil, unsubscribe: .never, markRead: false,
        protectRecentDays: 7, keepNewestPerSender: 2,
        guardTransactional: true, guardContacted: true,
        autoUnsubscribeMinimumUnreadRatio: 0.95, autoUnsubscribeMinimumMessages: 20,
        autoUnsubscribeRequiresNeverContacted: true)

    public static let balanced = CleanupPolicy(
        disposition: .fileIntoFolders, promotionDisposition: nil, unsubscribe: .automaticOneClick, markRead: true,
        protectRecentDays: 2, keepNewestPerSender: 1,
        guardTransactional: true, guardContacted: true,
        autoUnsubscribeMinimumUnreadRatio: 0.9, autoUnsubscribeMinimumMessages: 10,
        autoUnsubscribeRequiresNeverContacted: true)

    public static let thorough = CleanupPolicy(
        disposition: .fileIntoFolders, promotionDisposition: .trash, unsubscribe: .automaticOneClick, markRead: true,
        protectRecentDays: 0, keepNewestPerSender: 0,
        guardTransactional: true, guardContacted: true,
        autoUnsubscribeMinimumUnreadRatio: 0.75, autoUnsubscribeMinimumMessages: 5,
        autoUnsubscribeRequiresNeverContacted: false)

    public static func preset(_ preset: Preset) -> CleanupPolicy {
        switch preset {
        case .gentle: gentle
        case .balanced: balanced
        case .thorough: thorough
        case .custom: current
        }
    }

    /// Which preset this policy matches, or `.custom`.
    public var matchingPreset: Preset {
        if self == .gentle { return .gentle }
        if self == .balanced { return .balanced }
        if self == .thorough { return .thorough }
        return .custom
    }

    // MARK: - Per-category disposition

    public func disposition(for category: SenderCategory) -> Disposition {
        category == .promotion ? (promotionDisposition ?? disposition) : disposition
    }

    // MARK: - Persistence

    static let defaultsKey = "grokbox.cleanupPolicy"

    /// The policy in force. Defaults to `.gentle` — the safest thing that is
    /// still useful — for anyone who never opens Settings.
    public static var current: CleanupPolicy {
        get { load() }
        set { save(newValue) }
    }

    public static func load(from defaults: UserDefaults = .standard) -> CleanupPolicy {
        guard let data = defaults.data(forKey: defaultsKey),
              let policy = try? JSONDecoder().decode(CleanupPolicy.self, from: data) else { return .gentle }
        return policy
    }

    public static func save(_ policy: CleanupPolicy, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    // MARK: - Plain-language summary

    /// One paragraph describing exactly what a sweep will do under this
    /// policy. Shown above the Sweep button, so nobody has to infer it.
    public var summary: String {
        var parts: [String] = []
        switch disposition {
        case .fileIntoFolders: parts.append("Files swept mail into Grokbox folders by kind")
        case .archiveOnly: parts.append("Archives swept mail without filing it")
        case .trash: parts.append("Moves swept mail to your provider's Trash")
        }
        if let promo = promotionDisposition, promo != disposition {
            parts.append("promotions go to \(promo == .trash ? "the Trash" : promo == .archiveOnly ? "the archive" : "folders")")
        }
        if markRead { parts.append("marks it read") }
        var holds: [String] = []
        if protectRecentDays > 0 { holds.append("anything from the last \(protectRecentDays) day\(protectRecentDays == 1 ? "" : "s")") }
        if keepNewestPerSender > 0 { holds.append("the newest \(keepNewestPerSender) from each sender") }
        if guardTransactional { holds.append("receipts and security mail") }
        if guardContacted { holds.append("senders you have written to") }
        holds.append("flagged mail and anything that needs you")
        var text = parts.joined(separator: ", ") + ". Keeps " + holds.joined(separator: ", ") + "."
        switch unsubscribe {
        case .never: text += " Never unsubscribes on its own."
        case .automaticOneClick:
            var conditions = ["at least \(Int(autoUnsubscribeMinimumUnreadRatio * 100))% unread", "\(autoUnsubscribeMinimumMessages)+ messages"]
            if autoUnsubscribeRequiresNeverContacted { conditions.append("never written back") }
            text += " Unsubscribes automatically from senders with a one-click link, " + conditions.joined(separator: ", ") + "."
        }
        return text
    }
}
