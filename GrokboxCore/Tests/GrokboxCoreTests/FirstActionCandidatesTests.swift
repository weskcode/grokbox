import Foundation
import Testing
@testable import GrokboxCore

struct FirstActionCandidatesTests {
    private func item(_ address: String, count: Int, fromRule: Bool = false, enabled: Bool = true,
                      guarded: Int? = nil) -> CleanupPlan.Item {
        let cluster = SenderCluster(
            address: address, displayName: address, domain: "example.com", mailbox: "INBOX",
            uids: (0..<count).map { UInt32($0 + 1) }, unreadUIDs: [],
            messageCount: count, unreadCount: count, flaggedCount: 0, sweptCount: 0,
            newest: .now, oldest: .now, hasUnsubscribeLink: false, unsubscribeValue: nil,
            supportsOneClickUnsubscribe: false, everContacted: false, sampleSubjects: [], category: .newsletter)
        var item = CleanupPlan.Item(cluster: cluster, isEnabled: enabled, isFromRule: fromRule)
        item.guardedCount = guarded
        return item
    }

    private func advice(_ recommendation: Recommendation, _ reason: String = "reason") -> (recommendation: Recommendation, reason: String) {
        (recommendation, reason)
    }

    @Test func takesAtMostThree() {
        let plan = CleanupPlan(items: (1...6).map { item("s\($0)@example.com", count: 10 + $0) })
        let advice = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.cluster.address, advice(.fileAutomatically)) })
        #expect(FirstActionCandidates.select(from: plan, advice: advice).count == 3)
    }

    @Test func ranksUnsubscribeAdviceFirstThenCountThenAddress() {
        let plan = CleanupPlan(items: [
            item("b@example.com", count: 50), item("a@example.com", count: 50),
            item("big@example.com", count: 500), item("small@example.com", count: 5),
        ])
        let advice: [String: (recommendation: Recommendation, reason: String)] = [
            "b@example.com": advice(.fileAutomatically), "a@example.com": advice(.fileAutomatically),
            "big@example.com": advice(.fileAutomatically), "small@example.com": advice(.unsubscribeAndSweep),
        ]
        let picked = FirstActionCandidates.select(from: plan, advice: advice).map(\.item.cluster.address)
        #expect(picked == ["small@example.com", "big@example.com", "a@example.com"])
    }

    @Test func skipsSendersThatAreNotSweepAdvice() {
        let plan = CleanupPlan(items: [
            item("keep@example.com", count: 90), item("review@example.com", count: 80),
            item("mute@example.com", count: 70), item("none@example.com", count: 60),
            item("ok@example.com", count: 10),
        ])
        let advice: [String: (recommendation: Recommendation, reason: String)] = [
            "keep@example.com": advice(.keep), "review@example.com": advice(.review),
            "mute@example.com": advice(.muteNotifications), "ok@example.com": advice(.fileAutomatically),
        ]
        let picked = FirstActionCandidates.select(from: plan, advice: advice).map(\.item.cluster.address)
        #expect(picked == ["ok@example.com"])
    }

    @Test func skipsAlreadyApprovedDisabledAndEmptySenders() {
        let plan = CleanupPlan(items: [
            item("rule@example.com", count: 40, fromRule: true),
            item("off@example.com", count: 40, enabled: false),
            item("held@example.com", count: 40, guarded: 0),
            item("good@example.com", count: 40, guarded: 12),
        ])
        let advice = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.cluster.address, advice(.unsubscribeAndSweep)) })
        let picked = FirstActionCandidates.select(from: plan, advice: advice)
        #expect(picked.map(\.item.cluster.address) == ["good@example.com"])
        #expect(picked.first?.item.messageCount == 12)
    }

    @Test func ranksByTheGuardedCountWhenKnown() {
        let plan = CleanupPlan(items: [
            item("many@example.com", count: 300, guarded: 4), item("fewer@example.com", count: 100, guarded: 90),
        ])
        let advice = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.cluster.address, advice(.fileAutomatically)) })
        #expect(FirstActionCandidates.select(from: plan, advice: advice).map(\.item.cluster.address)
                == ["fewer@example.com", "many@example.com"])
    }

    @Test func noAdviceMeansNoCandidate() {
        let plan = CleanupPlan(items: [item("x@example.com", count: 20)])
        #expect(FirstActionCandidates.select(from: plan, advice: [:]).isEmpty)
        #expect(FirstActionCandidates.select(from: CleanupPlan(items: []), advice: [:]).isEmpty)
    }

    @Test func carriesTheRecommendersOwnReason() {
        let plan = CleanupPlan(items: [item("x@example.com", count: 20)])
        let picked = FirstActionCandidates.select(from: plan, advice: ["x@example.com": advice(.fileAutomatically, "You open these fairly often (60%).")])
        #expect(picked.first?.reason == "You open these fairly often (60%).")
        #expect(picked.first?.recommendation == .fileAutomatically)
    }

    @Test func selectionNeverChangesThePlan() {
        let plan = CleanupPlan(items: [item("x@example.com", count: 20), item("y@example.com", count: 30)])
        let advice = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.cluster.address, advice(.fileAutomatically)) })
        _ = FirstActionCandidates.select(from: plan, advice: advice)
        #expect(plan.items.map(\.cluster.address) == ["x@example.com", "y@example.com"])
        #expect(plan.items.allSatisfy { $0.isEnabled && !$0.isFromRule })
    }
}

struct IndexCoverageTests {
    @Test func fullyIndexedIsComplete() {
        #expect(IndexCoverage(indexed: 900, mailboxTotal: 900) == .complete(indexed: 900))
        #expect(IndexCoverage(indexed: 950, mailboxTotal: 900) == .complete(indexed: 950))
        #expect(IndexCoverage(indexed: 0, mailboxTotal: 0) == .complete(indexed: 0))
    }

    @Test func fewerThanTheMailboxHoldsIsPartial() {
        #expect(IndexCoverage(indexed: 1_000, mailboxTotal: 18_432) == .partial(indexed: 1_000, of: 18_432))
        #expect(IndexCoverage(indexed: 0, mailboxTotal: 5) == .partial(indexed: 0, of: 5))
    }

    @Test func anUnknownMailboxSizeIsNeverCalledComplete() {
        #expect(IndexCoverage(indexed: 1_000, mailboxTotal: nil) == .unknown(indexed: 1_000))
    }

    @Test func onlyAPartialIndexNeedsAWarning() {
        #expect(IndexCoverage.partial(indexed: 1, of: 2).isPartial)
        #expect(!IndexCoverage.complete(indexed: 2).isPartial)
        #expect(!IndexCoverage.unknown(indexed: 2).isPartial)
        #expect(IndexCoverage.partial(indexed: 1, of: 2).indexed == 1)
    }
}
