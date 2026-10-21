import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

@MainActor
@Suite(.serialized)
struct RulePreviewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let address = "deals@shop.example"

    private struct Message {
        var uid: UInt32
        var subject: String
        var flagged = false
        var daysOld = 30
    }

    private func account(_ name: String, in context: ModelContext) -> MailAccount {
        let account = MailAccount(displayName: name, username: "\(name)@mail.example", host: "127.0.0.1", port: 0, kind: .demo, security: .none)
        context.insert(account)
        return account
    }

    @discardableResult
    private func seed(_ messages: [Message], for account: MailAccount, address: String? = nil,
                      category: SenderCategory = .promotion, oneClick: Bool = true,
                      verdict: Verdict = .bulk, in context: ModelContext) -> SenderProfile {
        let address = address ?? self.address
        let profile = SenderProfile(accountID: account.id, address: address)
        profile.displayName = "Shop"
        profile.mailbox = "INBOX"
        profile.pendingUIDs = messages.map(\.uid)
        profile.messageCount = messages.count
        profile.unreadCount = messages.count
        profile.verdictRaw = verdict.rawValue
        profile.categoryRaw = category.rawValue
        profile.hasUnsubscribeLink = oneClick
        profile.supportsOneClickUnsubscribe = oneClick
        profile.unsubscribeValue = oneClick ? "<https://shop.example/u>" : nil
        profile.updatedAt = now
        context.insert(profile)
        for message in messages {
            context.insert(MessageHeader(accountID: account.id, uid: message.uid, mailbox: "INBOX", subject: message.subject,
                                         senderName: "Shop", senderAddress: address,
                                         receivedAt: now.addingTimeInterval(-Double(message.daysOld) * 86_400),
                                         isUnread: true, isFlagged: message.flagged, listUnsubscribe: nil,
                                         listUnsubscribePost: nil, listID: nil, messageID: nil))
        }
        return profile
    }

    private func bulk(_ count: Int) -> [Message] {
        (1...count).map { Message(uid: UInt32($0), subject: "Sale \($0)", daysOld: $0) }
    }

    private func sweep(_ preview: RulePreview, at index: Int = 0) throws -> RulePreview.Sweep {
        guard case .sweeps(let sweep) = preview.accounts[index].outcome else {
            Issue.record("expected a sweep, got \(preview.accounts[index].outcome)")
            throw CancellationError()
        }
        return sweep
    }

    @Test func previewWritesNothing() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        seed(bulk(8), for: account("Home", in: context), in: context)
        try context.save()

        let preview = try RulePreview.make(address: address, edit: .customFolder("Clients/VIP"), policy: .thorough, in: context, now: now)

        #expect(try sweep(preview).folder == "Clients/VIP")
        #expect(!context.hasChanges, "building a preview must leave the context untouched")
        #expect(try context.fetch(FetchDescriptor<SenderRule>()).isEmpty, "no rule is written")
        #expect(try context.fetch(FetchDescriptor<CleanupAction>()).isEmpty, "nothing is logged")
    }

    @Test func previewAgreesWithThePlanASweepBuildsAfterTheRuleIsSaved() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let home = account("Home", in: context)
        var messages = bulk(10)
        messages[2].flagged = true
        messages[4].subject = "Your receipt for order #123"
        let profile = seed(messages, for: home, in: context)
        try context.save()

        for edit in [RuleEdit.decision(.sweep), .disposition(.trash), .autoUnsubscribe(true), .customFolder("Clients/VIP")] {
            let preview = try RulePreview.make(address: address, edit: edit, policy: .balanced, in: context, now: now)
            try RuleStore.apply(edit, for: address, in: context)
            var plan = CleanupPlan.suggested(from: [profile.assessment], rules: RuleStore.all(in: context), policy: .balanced,
                                             overrides: RuleStore.overrides(in: context))
            plan.previewGuard(policy: .balanced, now: now) { cluster in
                (try? SweepGuard.MessageFacts.load(uids: cluster.pendingUIDs, accountID: home.id, in: context)) ?? []
            }
            let item = try #require(plan.items.first, "\(edit)")
            let shown = try sweep(preview)

            #expect(shown.disposition == item.disposition, "\(edit)")
            #expect(shown.folder == item.folder, "\(edit)")
            #expect(shown.unsubscribe == item.unsubscribe, "\(edit)")
            #expect(shown.affectedCount == item.guardedCount, "\(edit)")
            #expect(shown.heldCount == item.heldCount, "\(edit)")
            try RuleStore.clear(for: address, in: context)
        }
    }

    @Test func heldMessagesNameTheirReason() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        var messages = bulk(6)
        messages[0].flagged = true
        messages[1].subject = "Invoice for May"
        seed(messages, for: account("Home", in: context), in: context)

        let sweep = try sweep(try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough, in: context, now: now))

        #expect(sweep.affectedCount == 4)
        #expect(sweep.heldCount == 2)
        let reasons = Dictionary(uniqueKeysWithValues: sweep.held.map { ($0.uid, $0.heldReason) })
        #expect(reasons[1] == "flagged")
        #expect(reasons[2] == "looks transactional")
        #expect(sweep.affected.allSatisfy { $0.heldReason == nil })
        #expect(sweep.affected.map(\.uid) == [3, 4, 5, 6], "newest first")
    }

    @Test func samplesAreCappedButCountsAreNot() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        seed(bulk(40), for: account("Home", in: context), in: context)

        let sweep = try sweep(try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough,
                                               in: context, now: now, sampleLimit: 3))
        #expect(sweep.affectedCount == 40)
        #expect(sweep.affected.count == 3)
    }

    @Test func aRuleCoversTheSenderInEveryAccount() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        seed(bulk(5), for: account("Work", in: context), in: context)
        seed(bulk(7), for: account("Home", in: context), in: context)

        let preview = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough, in: context, now: now)

        #expect(preview.accounts.map(\.accountName) == ["Home", "Work"])
        #expect(try sweep(preview, at: 0).affectedCount == 7)
        #expect(try sweep(preview, at: 1).affectedCount == 5)
    }

    @Test func irreversibleEffectsAreListedOnlyWhenMailWouldMove() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let home = account("Home", in: context)
        let profile = seed(bulk(30), for: home, in: context)

        let both = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough, in: context, now: now)
        #expect(both.irreversibleEffects == [.unsubscribeRequest, .movesToTrash])

        let neither = try RulePreview.make(address: address, edit: .autoUnsubscribe(false), policy: .gentle, in: context, now: now)
        #expect(neither.irreversibleEffects.isEmpty)

        let forced = try RulePreview.make(address: address, edit: .autoUnsubscribe(true), policy: .gentle, in: context, now: now)
        #expect(forced.irreversibleEffects == [.unsubscribeRequest], "a per-sender override works under Gentle")

        profile.pendingUIDs = [1]
        let flagged = try context.fetch(FetchDescriptor<MessageHeader>()).first { $0.uid == 1 }
        flagged?.isFlagged = true
        let allHeld = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough, in: context, now: now)
        #expect(allHeld.irreversibleEffects.isEmpty, "a sender whose mail is all held is not unsubscribed")
    }

    @Test func aKeepRuleProposesNothing() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        seed(bulk(5), for: account("Home", in: context), in: context)

        let preview = try RulePreview.make(address: address, edit: .decision(.keep), policy: .thorough, in: context, now: now)
        #expect(preview.accounts.first?.outcome == .keptInInbox)
        #expect(preview.irreversibleEffects.isEmpty)
    }

    @Test func clearingARuleShowsWhatTheSenderWouldDoWithoutIt() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let home = account("Home", in: context)
        seed(bulk(5), for: home, address: "friend@x.example", category: .person, oneClick: false, verdict: .review, in: context)
        try RuleStore.set(.sweep, for: "friend@x.example", in: context)

        let cleared = try RulePreview.make(address: "friend@x.example", edit: .clear, policy: .thorough, in: context, now: now)
        #expect(cleared.accounts.first?.outcome == .notProposed, "a review sender is not swept without a rule")
        #expect(cleared.resultingRule == nil)

        let swept = try RulePreview.make(address: "friend@x.example", edit: .decision(.sweep), policy: .thorough, in: context, now: now)
        #expect(try sweep(swept).affectedCount == 5)
    }

    @Test func aSenderWithNothingPendingSaysSo() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        seed([], for: account("Home", in: context), in: context)

        let preview = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough, in: context, now: now)
        #expect(preview.accounts.first?.outcome == .nothingPending)
    }

    @Test func sameEffectSeesChangesOutsideTheCappedSamples() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        seed(bulk(30), for: account("Home", in: context), in: context)

        let before = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough,
                                          in: context, now: now, sampleLimit: 3)
        // uid 30 is the oldest, far outside the three newest samples.
        let oldest = try #require(try context.fetch(FetchDescriptor<MessageHeader>()).first { $0.uid == 30 })
        oldest.isFlagged = true
        let after = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough,
                                         in: context, now: now, sampleLimit: 3)

        #expect(try sweep(after).heldCount == 1)
        #expect(!after.sameEffect(as: before), "an unsampled message changed groups")
    }

    @Test func flagsChangedAfterThePreviewShowUpInTheNextOneAndInTheGuard() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let home = account("Home", in: context)
        seed(bulk(6), for: home, in: context)

        let before = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough, in: context, now: now)
        #expect(try sweep(before).heldCount == 0)

        // The person flags a message in their mail client; the next sync updates the index.
        let message = try #require(try context.fetch(FetchDescriptor<MessageHeader>()).first { $0.uid == 4 })
        message.isFlagged = true

        let after = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough, in: context, now: now)
        #expect(!after.sameEffect(as: before), "the screen can tell the answer moved")
        #expect(try sweep(after).held.map(\.uid) == [4])

        let atRunTime = SweepGuard.check(try SweepGuard.MessageFacts.load(uids: Array(1...6), accountID: home.id, in: context),
                                         policy: .thorough, now: now)
        #expect(!atRunTime.allowed.contains(4), "a sweep reads the same index when it runs")
        #expect(atRunTime.allowed.count == (try sweep(after)).affectedCount)

        let again = try RulePreview.make(address: address, edit: .decision(.sweep), policy: .thorough, in: context, now: now)
        #expect(again.sameEffect(as: after))
    }
}
