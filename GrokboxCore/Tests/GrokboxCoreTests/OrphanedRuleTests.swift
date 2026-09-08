import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

@MainActor
struct OrphanedRuleTests {
    /// The leak found on a real machine: sweep rules from demo mailboxes
    /// outlived the accounts and stayed live against a real Gmail.
    @Test func rulesForSendersNoAccountHasAreOrphaned() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let accountID = UUID()

        // One sender that still exists, one that does not.
        let profile = SenderProfile(accountID: accountID, address: "news@real.example")
        context.insert(profile)
        RuleStore.set(.sweep, for: "news@real.example", in: context)
        RuleStore.set(.sweep, for: "offers@gone.example", in: context)
        try context.save()

        let orphans = RuleStore.orphaned(in: context).map(\.address)
        #expect(orphans == ["offers@gone.example"])

        #expect(RuleStore.clearOrphaned(in: context) == 1)
        #expect(RuleStore.all(in: context).keys.sorted() == ["news@real.example"], "the live rule is kept")
        #expect(RuleStore.clearOrphaned(in: context) == 0, "and it is idempotent")
    }

    /// Global rules are the point: a sender shared by two accounts keeps its
    /// rule when one of those accounts goes away.
    @Test func aRuleSharedByTwoAccountsSurvivesLosingOne() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let keep = UUID(), remove = UUID()
        context.insert(SenderProfile(accountID: keep, address: "news@shared.example"))
        context.insert(SenderProfile(accountID: remove, address: "news@shared.example"))
        RuleStore.set(.sweep, for: "news@shared.example", in: context)
        try context.save()

        // Simulate removing one account: its profiles go, the other's remain.
        try context.delete(model: SenderProfile.self, where: #Predicate { $0.accountID == remove })
        try context.save()

        #expect(RuleStore.clearOrphaned(in: context) == 0)
        #expect(RuleStore.all(in: context)["news@shared.example"] == .sweep)
    }
}
