import Foundation

/// A sender, collapsed across every message they have sent you.
///
/// This collapse is the whole trick: 40,000 messages is an unreadable wall,
/// but the same mail is usually 400-odd senders, and decisions are made at the
/// sender level, not the message level.
public struct SenderCluster: Identifiable, Sendable, Hashable {
    public var id: String { address }

    public var address: String
    public var displayName: String
    public var domain: String
    public var mailbox: String
    public var uids: [UInt32]
    public var unreadUIDs: [UInt32]
    public var messageCount: Int
    public var unreadCount: Int
    public var flaggedCount: Int
    public var sweptCount: Int
    public var newest: Date
    public var oldest: Date
    public var hasUnsubscribeLink: Bool
    public var unsubscribeValue: String?
    public var supportsOneClickUnsubscribe: Bool
    public var everContacted: Bool
    public var sampleSubjects: [String]
    public var category: SenderCategory

    public var unreadRatio: Double {
        messageCount > 0 ? Double(unreadCount) / Double(messageCount) : 0
    }

    /// Messages not yet archived by Grokbox — what a sweep would touch.
    public var pendingUIDs: [UInt32] { uids }

    /// Best-guess HTTPS unsubscribe target from the List-Unsubscribe header
    /// (RFC 2369). Presented to the user; never followed automatically.
    public var unsubscribeURL: URL? {
        guard let value = unsubscribeValue else { return nil }
        let targets = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) }
        let preferred = targets.first { $0.hasPrefix("https://") } ?? targets.first { $0.hasPrefix("http://") }
        return preferred.flatMap(URL.init(string:))
    }

    public init(
        address: String, displayName: String, domain: String, mailbox: String,
        uids: [UInt32], unreadUIDs: [UInt32], messageCount: Int, unreadCount: Int,
        flaggedCount: Int, sweptCount: Int, newest: Date, oldest: Date,
        hasUnsubscribeLink: Bool, unsubscribeValue: String?, supportsOneClickUnsubscribe: Bool,
        everContacted: Bool, sampleSubjects: [String], category: SenderCategory = .unknown
    ) {
        self.address = address
        self.displayName = displayName
        self.domain = domain
        self.mailbox = mailbox
        self.uids = uids
        self.unreadUIDs = unreadUIDs
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.flaggedCount = flaggedCount
        self.sweptCount = sweptCount
        self.newest = newest
        self.oldest = oldest
        self.hasUnsubscribeLink = hasUnsubscribeLink
        self.unsubscribeValue = unsubscribeValue
        self.supportsOneClickUnsubscribe = supportsOneClickUnsubscribe
        self.everContacted = everContacted
        self.sampleSubjects = sampleSubjects
        self.category = category
    }
}

/// What Grokbox thinks should happen to a sender's mail.
///
/// A verdict is a *suggestion*. Nothing acts on it without the user approving
/// a plan first — see docs/DECISIONS.md ADR-0003.
public enum Verdict: String, Sendable, CaseIterable {
    case keep
    case review
    case bulk

    public var label: String {
        switch self {
        case .keep: "Keep"
        case .review: "Review"
        case .bulk: "Bulk"
        }
    }

    public var explanation: String {
        switch self {
        case .keep: "You have written to this sender, or you read their mail."
        case .review: "Mixed signals. Worth a look before deciding."
        case .bulk: "Machine-sent, unread, and you have never replied."
        }
    }
}

public struct SenderAssessment: Identifiable, Sendable, Hashable {
    public var id: String { cluster.id }
    public var cluster: SenderCluster
    public var verdict: Verdict
    public var score: Int
    public var reasons: [String]

    public init(cluster: SenderCluster, verdict: Verdict, score: Int, reasons: [String]) {
        self.cluster = cluster
        self.verdict = verdict
        self.score = score
        self.reasons = reasons
    }
}
