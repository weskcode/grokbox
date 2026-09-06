import Foundation
import Testing
@testable import GrokboxCore

struct RuleTests {
    private func assessment(_ address: String, verdict: Verdict, uids: [UInt32] = [1]) -> SenderAssessment {
        let cluster = SenderCluster(address: address, displayName: address, domain: "x", mailbox: "m", uids: uids, unreadUIDs: [], messageCount: uids.count, unreadCount: 0, flaggedCount: 0, sweptCount: 0, newest: .now, oldest: .now, hasUnsubscribeLink: false, unsubscribeValue: nil, supportsOneClickUnsubscribe: false, everContacted: false, sampleSubjects: [])
        return SenderAssessment(cluster: cluster, verdict: verdict, score: 0, reasons: [])
    }

    @Test func keepRuleRemovesBulkSender() {
        let plan = CleanupPlan.suggested(from: [assessment("news@x", verdict: .bulk)], rules: ["news@x": .keep])
        #expect(plan.items.isEmpty)
    }

    @Test func sweepRulePromotesReviewSender() {
        let plan = CleanupPlan.suggested(from: [assessment("shop@x", verdict: .review)], rules: ["shop@x": .sweep])
        #expect(plan.items.count == 1)
        #expect(plan.items[0].isFromRule)
    }

    @Test func maintenancePlanOnlyContainsApprovedSenders() {
        let plan = CleanupPlan.fromRules(
            [assessment("news@x", verdict: .bulk), assessment("approved@x", verdict: .review)],
            rules: ["approved@x": .sweep]
        )
        #expect(plan.items.map(\.id) == ["approved@x"], "a bulk verdict alone never sweeps unattended")
    }

    @Test func alreadySweptSendersAreSkipped() {
        let plan = CleanupPlan.fromRules([assessment("done@x", verdict: .bulk, uids: [])], rules: ["done@x": .sweep])
        #expect(plan.isEmpty)
    }
}
