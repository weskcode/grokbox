import Foundation
import SwiftData

/// One row per sender per account: the aggregate the UI actually reads.
///
/// Rebuilt by `SenderProfileBuilder` in one pass after every index, and
/// adjusted in place by `PlanExecutor` when mail is swept or restored. Views
/// query these (hundreds of rows) instead of `MessageHeader` (tens of
/// thousands), which is what keeps a 40,000-message inbox responsive.
@Model
public final class SenderProfile {
    /// `"<accountID>|<address>"` — SwiftData has no compound unique keys.
    @Attribute(.unique) public var key: String = ""
    #Index<SenderProfile>([\.accountID], [\.verdictRaw])

    public var accountID: UUID = UUID()
    public var address: String = ""
    public var displayName: String = ""
    public var domain: String = ""
    public var mailbox: String = ""

    public var messageCount: Int = 0
    public var unreadCount: Int = 0
    public var flaggedCount: Int = 0
    public var sweptCount: Int = 0
    /// UIDs still in the inbox and not swept — what a sweep would touch.
    public var pendingUIDs: [UInt32] = []

    public var newest: Date = Date.distantPast
    public var oldest: Date = Date.distantPast
    public var hasUnsubscribeLink: Bool = false
    public var unsubscribeValue: String?
    public var supportsOneClickUnsubscribe: Bool = false
    public var everContacted: Bool = false
    public var sampleSubjects: [String] = []

    // Precomputed by HeuristicAnalyzer at build time.
    public var score: Int = 0
    public var verdictRaw: String = Verdict.review.rawValue
    public var reasons: [String] = []

    // Category: heuristics first; the model may refine `.unknown` later.
    public var categoryRaw: String = SenderCategory.unknown.rawValue
    public var categoryEvidence: String = ""
    public var categoryConfident: Bool = false
    public var categoryFromModel: Bool = false

    public var recommendationRaw: String = Recommendation.review.rawValue
    public var recommendationReason: String = ""

    public var updatedAt: Date = Date()

    public static func key(accountID: UUID, address: String) -> String { "\(accountID.uuidString)|\(address)" }

    public var verdict: Verdict {
        get { Verdict(rawValue: verdictRaw) ?? .review }
        set { verdictRaw = newValue.rawValue }
    }

    public var category: SenderCategory {
        get { SenderCategory(rawValue: categoryRaw) ?? .unknown }
        set { categoryRaw = newValue.rawValue }
    }

    public var recommendation: Recommendation {
        get { Recommendation(rawValue: recommendationRaw) ?? .review }
        set { recommendationRaw = newValue.rawValue }
    }

    public var pendingCount: Int { pendingUIDs.count }
    public var unreadRatio: Double { messageCount > 0 ? Double(unreadCount) / Double(messageCount) : 0 }

    public init(accountID: UUID, address: String) {
        self.key = Self.key(accountID: accountID, address: address)
        self.accountID = accountID
        self.address = address
    }

    /// The value type the plan, executor, and unsubscribe service work with.
    public var cluster: SenderCluster {
        SenderCluster(
            address: address, displayName: displayName, domain: domain, mailbox: mailbox,
            uids: pendingUIDs, unreadUIDs: [], messageCount: messageCount, unreadCount: unreadCount,
            flaggedCount: flaggedCount, sweptCount: sweptCount, newest: newest, oldest: oldest,
            hasUnsubscribeLink: hasUnsubscribeLink, unsubscribeValue: unsubscribeValue,
            supportsOneClickUnsubscribe: supportsOneClickUnsubscribe, everContacted: everContacted,
            sampleSubjects: sampleSubjects, category: category
        )
    }

    public var assessment: SenderAssessment {
        SenderAssessment(cluster: cluster, verdict: verdict, score: score, reasons: reasons)
    }
}
