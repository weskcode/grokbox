import Foundation

/// A set of proposed actions the user reviews before anything runs.
///
/// Built from the sender assessments; nothing in it is executed until
/// `PlanExecutor.apply` is called with it. See docs/DECISIONS.md ADR-0003.
public struct CleanupPlan: Sendable {
    public struct Item: Identifiable, Sendable, Hashable {
        public var id: String { cluster.id }
        public var cluster: SenderCluster
        public var isEnabled: Bool
        public var archive: Bool
        public var markRead: Bool
        /// True when the user already approved this sender once; it needs no review.
        public var isFromRule: Bool
        /// What happens to this sender's mail, from the policy. Per item so
        /// promotions can be trashed while newsletters are filed.
        public var disposition: CleanupPolicy.Disposition
        /// Set when the policy says this sender qualifies for an automatic
        /// one-click unsubscribe as part of the sweep.
        public var unsubscribe: Bool
        /// How many of this sender's messages the guard will actually take,
        /// and how many it will hold back, under the current policy. Nil until
        /// `previewGuard` has run — the plan alone cannot know, because the
        /// reasons live on individual messages.
        public var guardedCount: Int?
        public var heldCount: Int = 0

        /// What a sweep will really touch: the guard's answer where it is
        /// known, the sender's pending mail otherwise.
        public var messageCount: Int { guardedCount ?? cluster.pendingUIDs.count }

        /// Where the swept mail goes — the category's folder, never a generic bin.
        public var folder: String { cluster.category.folderName }

        public init(cluster: SenderCluster, isEnabled: Bool = true, archive: Bool = true, markRead: Bool = true,
                    isFromRule: Bool = false, disposition: CleanupPolicy.Disposition = .fileIntoFolders, unsubscribe: Bool = false) {
            self.cluster = cluster
            self.isEnabled = isEnabled
            self.archive = archive
            self.markRead = markRead
            self.isFromRule = isFromRule
            self.disposition = disposition
            self.unsubscribe = unsubscribe
        }
    }

    public var items: [Item]

    /// Legacy single label; kept so old actions can still be undone.
    public static let sweptLabel = "Grokbox/Swept"

    /// Items grouped by folder, largest first — how Sweep presents them.
    public var byFolder: [(folder: String, category: SenderCategory, items: [Item])] {
        let groups = Dictionary(grouping: items, by: \.cluster.category)
        return groups
            .map { (folder: $0.key.folderName, category: $0.key, items: $0.value.sorted { $0.messageCount > $1.messageCount }) }
            .sorted { $0.items.reduce(0) { $0 + $1.messageCount } > $1.items.reduce(0) { $0 + $1.messageCount } }
    }

    public init(items: [Item]) {
        self.items = items
    }

    /// Everything the heuristics called bulk, plus anything the user has a
    /// `sweep` rule for, minus anything they have a `keep` rule for.
    /// Largest senders first.
    public static func suggested(from assessments: [SenderAssessment], rules: [String: RuleDecision] = [:],
                                 policy: CleanupPolicy = .current) -> CleanupPlan {
        let items = assessments
            .filter { !$0.cluster.pendingUIDs.isEmpty }
            .filter { rules[$0.cluster.address] != .keep }
            // A sender you have written to is a correspondent, whatever their
            // mail looks like — unless you explicitly ruled otherwise.
            .filter { !(policy.guardContacted && $0.cluster.everContacted) || rules[$0.cluster.address] == .sweep }
            .filter { $0.verdict == .bulk || rules[$0.cluster.address] == .sweep }
            .sorted { $0.cluster.messageCount > $1.cluster.messageCount }
            .map { Item(cluster: $0.cluster,
                        markRead: policy.markRead,
                        isFromRule: rules[$0.cluster.address] == .sweep,
                        disposition: policy.disposition(for: $0.cluster.category),
                        unsubscribe: qualifiesForAutoUnsubscribe($0.cluster, policy: policy)) }
        return CleanupPlan(items: items)
    }

    /// Whether the policy allows pressing this sender's one-click link without
    /// asking. Deliberately conservative: a real one-click endpoint, enough
    /// history to judge, mail you demonstrably do not read, and (by default)
    /// no evidence you ever wrote back.
    public static func qualifiesForAutoUnsubscribe(_ cluster: SenderCluster, policy: CleanupPolicy) -> Bool {
        guard policy.unsubscribe == .automaticOneClick else { return false }
        guard cluster.supportsOneClickUnsubscribe, cluster.unsubscribeURL != nil else { return false }
        guard cluster.messageCount >= policy.autoUnsubscribeMinimumMessages else { return false }
        guard cluster.category == .promotion || cluster.category == .newsletter || cluster.category == .notification else { return false }
        if policy.autoUnsubscribeRequiresNeverContacted && cluster.everContacted { return false }
        let unreadRatio = cluster.messageCount > 0 ? Double(cluster.unreadCount) / Double(cluster.messageCount) : 0
        return unreadRatio >= policy.autoUnsubscribeMinimumUnreadRatio
    }

    /// Only senders the user has already approved. This is what maintenance
    /// applies unattended — new suggestions always wait for a human.
    public static func fromRules(_ assessments: [SenderAssessment], rules: [String: RuleDecision],
                                 policy: CleanupPolicy = .current) -> CleanupPlan {
        let items = assessments
            .filter { !$0.cluster.pendingUIDs.isEmpty && rules[$0.cluster.address] == .sweep }
            .map { Item(cluster: $0.cluster, markRead: policy.markRead, isFromRule: true,
                        disposition: policy.disposition(for: $0.cluster.category),
                        unsubscribe: qualifiesForAutoUnsubscribe($0.cluster, policy: policy)) }
        return CleanupPlan(items: items)
    }

    /// Runs the message-level guard over the plan so the count shown to the
    /// user is the count that will happen. The executor checks again at run
    /// time against live data; this is the honest preview, not the authority.
    public mutating func previewGuard(policy: CleanupPolicy, now: Date = Date(),
                                      facts: (SenderCluster) -> [SweepGuard.MessageFacts]) {
        items = items.map { item in
            var item = item
            let verdict = SweepGuard.check(facts(item.cluster), policy: policy, now: now)
            item.guardedCount = verdict.allowed.count
            item.heldCount = verdict.held.count
            return item
        }
        // A sender whose every message is held has nothing left to propose.
        items.removeAll { $0.guardedCount == 0 }
    }

    /// How many messages the guard is holding back across the plan.
    public var heldMessageCount: Int { enabledItems.reduce(0) { $0 + $1.heldCount } }

    public var enabledItems: [Item] { items.filter(\.isEnabled) }
    /// Senders this plan will unsubscribe from without asking.
    public var autoUnsubscribeItems: [Item] { enabledItems.filter(\.unsubscribe) }
    public var enabledMessageCount: Int { enabledItems.reduce(0) { $0 + $1.messageCount } }
    public var isEmpty: Bool { enabledItems.isEmpty }
}
