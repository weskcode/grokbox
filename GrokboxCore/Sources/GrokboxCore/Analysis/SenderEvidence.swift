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

    /// Throws when the index cannot be read, so a failed fetch never shows as
    /// an empty or complete index. Dates come from the headers being counted.
    @MainActor
    public static func current(for account: MailAccount, in context: ModelContext) throws -> IndexCoverage {
        let accountID = account.id
        let matches = #Predicate<MessageHeader> { $0.accountID == accountID }
        var first = FetchDescriptor<MessageHeader>(predicate: matches, sortBy: [SortDescriptor(\.receivedAt)])
        first.fetchLimit = 1
        var last = FetchDescriptor<MessageHeader>(predicate: matches, sortBy: [SortDescriptor(\.receivedAt, order: .reverse)])
        last.fetchLimit = 1
        let snapshots = try context.fetch(FetchDescriptor<MailboxSnapshot>(predicate: #Predicate { $0.accountID == accountID }))
        return IndexCoverage(
            indexedMessages: try context.fetchCount(FetchDescriptor<MessageHeader>(predicate: matches)),
            serverMessages: snapshots.isEmpty ? nil : snapshots.reduce(0) { $0 + $1.messageCountOnServer },
            oldest: try context.fetch(first).first?.receivedAt,
            newest: try context.fetch(last).first?.receivedAt,
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

extension IndexCoverage {
    /// "Index covers 4,812 of 6,030 messages · partial · Mar 2, 2025 – Oct 20, 2026 · Updated 9 days ago, may be out of date"
    public func caption(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard !isEmpty else { return "Nothing indexed yet" }
        var parts: [String]
        if let serverMessages {
            parts = isPartial ? ["Index covers \(indexedMessages.formatted()) of \(serverMessages.formatted()) messages", "partial"]
                              : ["Index covers all \(indexedMessages.formatted()) messages"]
        } else {
            parts = ["Index covers \(indexedMessages.formatted()) messages"]
        }
        if let oldest, let newest {
            let style = Date.FormatStyle().month(.abbreviated).day().year()
            parts.append("\(oldest.formatted(style)) – \(newest.formatted(style))")
        }
        if let lastIndexedAt {
            let days = max(0, calendar.dateComponents([.day], from: lastIndexedAt, to: now).day ?? 0)
            let age = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
            parts.append("Updated \(age)" + (isStale(now: now, calendar: calendar) ? ", may be out of date" : ""))
        }
        return parts.joined(separator: " · ")
    }
}

extension SenderEvidence {
    /// What a sweep of this sender would do right now under their current rule,
    /// or under a sweep rule when they have none, taken from the same preview a
    /// rule edit shows. Nothing is written.
    @MainActor
    public static func sweepNow(address: String, accountID: UUID, rule: SenderRule?, policy: CleanupPolicy = .current,
                                in context: ModelContext) throws -> RulePreview.Outcome? {
        let edit = rule.map { RuleEdit.replace(SenderOverride(rule: $0)) } ?? .decision(.sweep)
        let preview = try RulePreview.make(address: address, edit: edit, policy: policy, in: context)
        return preview.accounts.first { $0.accountID == accountID }?.outcome
    }

    /// The rule's reach in words. `accountNames` names the other accounts the rule also covers.
    public func scope(accountNames: [UUID: String]) -> String {
        let base = ruleSummary.map { "Rule: \($0). It applies to this address in every account." }
            ?? "No rule yet. A rule applies to this address in every account."
        guard !otherAccounts.isEmpty else { return base }
        let others = otherAccounts.map { other in
            "\(accountNames[other.accountID] ?? "another account") (\(Self.messages(other.messageCount)))"
        }
        return base + " Also seen in " + others.joined(separator: ", ") + "."
    }

    static func messages(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "message" : "messages")" }
}

/// The "If you sweep now" block, as words.
public struct SweepNowText: Sendable, Equatable {
    public var moves: String
    /// Nil when nothing is held.
    public var held: String?
    /// Up to three of the held messages, each with the guard's reason.
    public var heldDetails: [String]

    public init(_ outcome: RulePreview.Outcome) {
        switch outcome {
        case .sweeps(let sweep):
            moves = sweep.affectedCount == 0 ? "Nothing would move."
                : "Moves \(SenderEvidence.messages(sweep.affectedCount)) to \(sweep.destination)."
            held = sweep.heldCount == 0 ? nil : "\(sweep.heldCount.formatted()) stay in the inbox."
            heldDetails = sweep.held.prefix(3).map { "\($0.subject): \($0.heldReason ?? "held")" }
        case .keptInInbox:
            (moves, held, heldDetails) = ("Your rule keeps this sender in the inbox. Nothing moves.", nil, [])
        case .nothingPending:
            (moves, held, heldDetails) = ("Nothing from this sender is left in the inbox.", nil, [])
        case .notProposed:
            (moves, held, heldDetails) = ("No sweep is proposed for this sender.", nil, [])
        }
    }
}

