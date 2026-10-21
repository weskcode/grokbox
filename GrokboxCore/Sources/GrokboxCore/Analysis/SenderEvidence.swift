import Foundation
import SwiftData

/// How much of an account's mail the index actually covers, so a count on
/// screen can say what it is a count of.
public struct IndexCoverage: Sendable, Equatable {
    public var indexedMessages: Int
    /// What the server last reported for the indexed mailbox. Nil before the first index.
    public var serverMessages: Int?
    public var oldest: Date?
    public var newest: Date?
    public var lastIndexedAt: Date?

    /// A shorter-than-the-server index is partial. Mail that is gone from the
    /// server can leave the index larger, which is not partial.
    public var isPartial: Bool {
        guard let serverMessages else { return false }
        return indexedMessages < serverMessages
    }

    public var isEmpty: Bool { indexedMessages == 0 }

    public static let staleAfterDays = 7

    public func isStale(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let lastIndexedAt else { return false }
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.staleAfterDays, to: now) else { return false }
        return lastIndexedAt < cutoff
    }

    public init(indexedMessages: Int, serverMessages: Int?, oldest: Date?, newest: Date?, lastIndexedAt: Date?) {
        self.indexedMessages = indexedMessages
        self.serverMessages = serverMessages
        self.oldest = oldest
        self.newest = newest
        self.lastIndexedAt = lastIndexedAt
    }

    @MainActor
    public static func current(for account: MailAccount, in context: ModelContext) -> IndexCoverage {
        let accountID = account.id
        let indexed = (try? context.fetchCount(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == accountID }))) ?? 0
        let snapshots = (try? context.fetch(FetchDescriptor<MailboxSnapshot>(predicate: #Predicate { $0.accountID == accountID }))) ?? []
        let profiles = SenderProfileBuilder.profiles(for: account, in: context).filter { $0.messageCount > 0 }
        return IndexCoverage(
            indexedMessages: indexed,
            serverMessages: snapshots.isEmpty ? nil : snapshots.reduce(0) { $0 + $1.messageCountOnServer },
            oldest: profiles.map(\.oldest).min(),
            newest: profiles.map(\.newest).max(),
            lastIndexedAt: snapshots.map(\.lastIndexedAt).max()
        )
    }
}

/// What the sender sheet needs to explain a recommendation, taken only from
/// data the index already holds. Counts here are the same ones the cleanup
/// plan starts from: `inInbox` is the sender's pending mail.
public struct SenderEvidence: Sendable, Equatable {
    public struct OtherAccount: Sendable, Equatable {
        public var accountID: UUID
        public var messageCount: Int
    }

    public var indexed: Int
    public var inInbox: Int
    public var outOfInbox: Int
    public var unread: Int
    public var flagged: Int
    public var oldest: Date
    public var newest: Date
    public var recommendationReason: String
    public var reasons: [String]
    public var categoryEvidence: String
    public var everContacted: Bool
    /// Nil when the sender has no rule.
    public var ruleSummary: String?
    /// Rules are global by address, so a rule here, existing or new, also
    /// reaches every other account that receives mail from this sender.
    public var otherAccounts: [OtherAccount]

    public init(profile: SenderProfile, rule: SenderRule?, allProfiles: [SenderProfile]) {
        indexed = profile.messageCount
        inInbox = profile.pendingCount
        outOfInbox = max(0, profile.messageCount - profile.pendingCount)
        unread = profile.unreadCount
        flagged = profile.flaggedCount
        oldest = profile.oldest
        newest = profile.newest
        recommendationReason = profile.recommendationReason
        reasons = profile.reasons
        categoryEvidence = profile.categoryEvidence
        everContacted = profile.everContacted
        otherAccounts = allProfiles
            .filter { $0.address == profile.address && $0.accountID != profile.accountID }
            .map { OtherAccount(accountID: $0.accountID, messageCount: $0.messageCount) }
            .sorted { $0.messageCount > $1.messageCount }
        ruleSummary = rule?.summary
    }
}
