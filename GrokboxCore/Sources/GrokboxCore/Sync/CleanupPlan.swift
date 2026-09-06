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

        public var messageCount: Int { cluster.pendingUIDs.count }

        /// Where the swept mail goes — the category's folder, never a generic bin.
        public var folder: String { cluster.category.folderName }

        public init(cluster: SenderCluster, isEnabled: Bool = true, archive: Bool = true, markRead: Bool = true, isFromRule: Bool = false) {
            self.cluster = cluster
            self.isEnabled = isEnabled
            self.archive = archive
            self.markRead = markRead
            self.isFromRule = isFromRule
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
    public static func suggested(from assessments: [SenderAssessment], rules: [String: RuleDecision] = [:]) -> CleanupPlan {
        let items = assessments
            .filter { !$0.cluster.pendingUIDs.isEmpty }
            .filter { rules[$0.cluster.address] != .keep }
            .filter { $0.verdict == .bulk || rules[$0.cluster.address] == .sweep }
            .sorted { $0.cluster.messageCount > $1.cluster.messageCount }
            .map { Item(cluster: $0.cluster, isFromRule: rules[$0.cluster.address] == .sweep) }
        return CleanupPlan(items: items)
    }

    /// Only senders the user has already approved. This is what maintenance
    /// applies unattended — new suggestions always wait for a human.
    public static func fromRules(_ assessments: [SenderAssessment], rules: [String: RuleDecision]) -> CleanupPlan {
        let items = assessments
            .filter { !$0.cluster.pendingUIDs.isEmpty && rules[$0.cluster.address] == .sweep }
            .map { Item(cluster: $0.cluster, isFromRule: true) }
        return CleanupPlan(items: items)
    }

    public var enabledItems: [Item] { items.filter(\.isEnabled) }
    public var enabledMessageCount: Int { enabledItems.reduce(0) { $0 + $1.messageCount } }
    public var isEmpty: Bool { enabledItems.isEmpty }
}
