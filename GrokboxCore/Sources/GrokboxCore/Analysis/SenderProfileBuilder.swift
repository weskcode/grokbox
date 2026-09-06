import Foundation
import SwiftData

/// Turns an account's message headers into `SenderProfile` rows.
///
/// One pass, fetching only the columns it needs, so cost is linear in the
/// number of messages and runs once per index rather than once per render.
@MainActor
public enum SenderProfileBuilder {
    private struct Aggregate {
        var displayName = ""
        var domain = ""
        var mailbox = ""
        var messageCount = 0
        var unreadCount = 0
        var flaggedCount = 0
        var sweptCount = 0
        var pendingUIDs: [UInt32] = []
        var newest = Date.distantPast
        var oldest = Date.distantFuture
        var unsubscribeValue: String?
        var oneClick = false
        var samples: [(Date, String)] = []
    }

    @discardableResult
    public static func rebuild(for account: MailAccount, in context: ModelContext, analyzer: any Analyzer = HeuristicAnalyzer()) throws -> Int {
        let accountID = account.id
        var descriptor = FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == accountID })
        descriptor.propertiesToFetch = [
            \.uid, \.senderAddress, \.senderName, \.senderDomain, \.mailbox, \.subject, \.receivedAt,
            \.isUnread, \.isFlagged, \.isSweptLocally, \.isInInbox, \.listUnsubscribe, \.listUnsubscribePost
        ]
        let messages = try context.fetch(descriptor)
        let contacted = Set(try context.fetch(FetchDescriptor<ContactedAddress>()).map(\.address))

        var aggregates: [String: Aggregate] = [:]
        aggregates.reserveCapacity(1_024)

        for message in messages where !message.senderAddress.isEmpty {
            var agg = aggregates[message.senderAddress] ?? Aggregate()
            if agg.displayName.isEmpty, !message.senderName.isEmpty { agg.displayName = message.senderName }
            if agg.domain.isEmpty { agg.domain = message.senderDomain }
            if agg.mailbox.isEmpty { agg.mailbox = message.mailbox }
            agg.messageCount += 1
            if message.isUnread { agg.unreadCount += 1 }
            if message.isFlagged { agg.flaggedCount += 1 }
            if message.isSweptLocally { agg.sweptCount += 1 }
            if message.isInInbox && !message.isSweptLocally { agg.pendingUIDs.append(message.uid) }
            if message.receivedAt > agg.newest { agg.newest = message.receivedAt }
            if message.receivedAt < agg.oldest { agg.oldest = message.receivedAt }
            if agg.unsubscribeValue == nil, let value = message.listUnsubscribe, !value.isEmpty { agg.unsubscribeValue = value }
            if message.listUnsubscribePost?.localizedCaseInsensitiveContains("One-Click") == true { agg.oneClick = true }
            // Keep the three newest subjects without sorting everything.
            if agg.samples.count < 3 {
                agg.samples.append((message.receivedAt, message.subject))
            } else if let weakest = agg.samples.indices.min(by: { agg.samples[$0].0 < agg.samples[$1].0 }), message.receivedAt > agg.samples[weakest].0 {
                agg.samples[weakest] = (message.receivedAt, message.subject)
            }
            aggregates[message.senderAddress] = agg
        }

        // Existing rows, keyed for upsert; anything not seen again is stale.
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<SenderProfile>(predicate: #Predicate { $0.accountID == accountID })).map { ($0.address, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var seen = Set<String>()

        // Score everything in one go so the sort order is consistent.
        let clusters = aggregates.map { address, agg in cluster(address: address, agg, contacted: contacted) }
        let assessed = analyzer.assess(clusters)

        for assessment in assessed {
            let address = assessment.cluster.address
            seen.insert(address)
            let profile = existing[address] ?? SenderProfile(accountID: accountID, address: address)
            if existing[address] == nil { context.insert(profile) }
            apply(assessment, to: profile)

            // A model-assigned category is more informed than the heuristics;
            // keep it unless the heuristics are now confident.
            let categorised = SenderCategorizer.categorize(assessment.cluster)
            if !(profile.categoryFromModel && !categorised.confident) {
                profile.category = categorised.category
                profile.categoryEvidence = categorised.evidence
                profile.categoryConfident = categorised.confident
                profile.categoryFromModel = false
            }
            let advice = Recommender.recommend(assessment, category: profile.category)
            profile.recommendation = advice.recommendation
            profile.recommendationReason = advice.reason
        }
        for (address, profile) in existing where !seen.contains(address) {
            context.delete(profile)
        }
        try context.save()
        return assessed.count
    }

    private static func cluster(address: String, _ agg: Aggregate, contacted: Set<String>) -> SenderCluster {
        SenderCluster(
            address: address,
            displayName: agg.displayName.isEmpty ? address : agg.displayName,
            domain: agg.domain, mailbox: agg.mailbox,
            uids: agg.pendingUIDs, unreadUIDs: [],
            messageCount: agg.messageCount, unreadCount: agg.unreadCount, flaggedCount: agg.flaggedCount,
            sweptCount: agg.sweptCount,
            newest: agg.newest, oldest: agg.oldest == .distantFuture ? agg.newest : agg.oldest,
            hasUnsubscribeLink: agg.unsubscribeValue != nil, unsubscribeValue: agg.unsubscribeValue,
            supportsOneClickUnsubscribe: agg.oneClick,
            everContacted: contacted.contains(address),
            sampleSubjects: agg.samples.sorted { $0.0 > $1.0 }.map(\.1)
        )
    }

    private static func apply(_ assessment: SenderAssessment, to profile: SenderProfile) {
        let c = assessment.cluster
        profile.displayName = c.displayName
        profile.domain = c.domain
        profile.mailbox = c.mailbox
        profile.messageCount = c.messageCount
        profile.unreadCount = c.unreadCount
        profile.flaggedCount = c.flaggedCount
        profile.sweptCount = c.sweptCount
        profile.pendingUIDs = c.uids
        profile.newest = c.newest
        profile.oldest = c.oldest
        profile.hasUnsubscribeLink = c.hasUnsubscribeLink
        profile.unsubscribeValue = c.unsubscribeValue
        profile.supportsOneClickUnsubscribe = c.supportsOneClickUnsubscribe
        profile.everContacted = c.everContacted
        profile.sampleSubjects = c.sampleSubjects
        profile.score = assessment.score
        profile.verdict = assessment.verdict
        profile.reasons = assessment.reasons
        profile.updatedAt = Date()
    }

    // MARK: - Queries

    public static func profiles(for account: MailAccount, in context: ModelContext) -> [SenderProfile] {
        let accountID = account.id
        return (try? context.fetch(FetchDescriptor<SenderProfile>(predicate: #Predicate { $0.accountID == accountID }))) ?? []
    }

    public static func assessments(for account: MailAccount, in context: ModelContext) -> [SenderAssessment] {
        profiles(for: account, in: context).map(\.assessment).sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.cluster.messageCount > rhs.cluster.messageCount
        }
    }

    public static func verdictMap(for account: MailAccount, in context: ModelContext) -> [String: Verdict] {
        Dictionary(profiles(for: account, in: context).map { ($0.address, $0.verdict) }, uniquingKeysWith: { a, _ in a })
    }

    /// Applies a model's category to a profile and refreshes the recommendation.
    public static func setModelCategory(_ category: SenderCategory, evidence: String, on profile: SenderProfile) {
        profile.category = category
        profile.categoryEvidence = evidence
        profile.categoryConfident = true
        profile.categoryFromModel = true
        let advice = Recommender.recommend(profile.assessment, category: category)
        profile.recommendation = advice.recommendation
        profile.recommendationReason = advice.reason
        profile.updatedAt = Date()
    }

    /// Adjusts one sender's row after a sweep (`swept: true`) or undo without
    /// re-scanning the mailbox.
    public static func adjust(accountID: UUID, address: String, uids: [UInt32], swept: Bool, in context: ModelContext) {
        let key = SenderProfile.key(accountID: accountID, address: address)
        guard let profile = try? context.fetch(FetchDescriptor<SenderProfile>(predicate: #Predicate { $0.key == key })).first else { return }
        let set = Set(uids)
        if swept {
            let removed = profile.pendingUIDs.filter { set.contains($0) }.count
            profile.pendingUIDs.removeAll { set.contains($0) }
            profile.sweptCount += removed
        } else {
            let restored = Array(set.subtracting(profile.pendingUIDs))
            profile.pendingUIDs.append(contentsOf: restored)
            profile.sweptCount = max(0, profile.sweptCount - restored.count)
        }
        profile.updatedAt = Date()
    }
}
