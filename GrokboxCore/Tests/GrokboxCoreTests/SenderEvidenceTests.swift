import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

@MainActor
@Suite(.serialized)
struct SenderEvidenceTests {
    private func container() throws -> ModelContainer {
        let schema = Schema([MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self, SenderRule.self, MailboxSnapshot.self, SenderProfile.self, InboxDigest.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func account(_ name: String, in context: ModelContext) -> MailAccount {
        let account = MailAccount(displayName: name, username: "\(name)@x", host: "h", port: 1, kind: .generic, security: .tls)
        context.insert(account)
        return account
    }

    @discardableResult
    private func addMessages(_ count: Int, from address: String, name: String = "Sender", to account: MailAccount,
                             inboxEvery: Int = 1, firstUID: UInt32 = 1, in context: ModelContext) -> UInt32 {
        var uid = firstUID
        for index in 0..<count {
            context.insert(MessageHeader(
                accountID: account.id, uid: uid, mailbox: "INBOX", subject: "Subject \(index)", senderName: name, senderAddress: address,
                receivedAt: Date(timeIntervalSinceNow: -Double(index + 1) * 86_400), isUnread: index % 2 == 0, isFlagged: false,
                listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil, messageID: nil, isInInbox: index % inboxEvery == 0))
            uid += 1
        }
        return uid
    }

    private func snapshot(_ account: MailAccount, onServer: Int, indexedAt: Date, in context: ModelContext) {
        let snapshot = MailboxSnapshot(accountID: account.id, mailbox: "INBOX", uidValidity: 1, highestUID: 1, messageCountOnServer: onServer)
        snapshot.lastIndexedAt = indexedAt
        context.insert(snapshot)
    }

    // MARK: Coverage

    @Test func anUnindexedAccountHasEmptyCoverage() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        let coverage = try IndexCoverage.current(for: account, in: context)
        #expect(coverage.isEmpty)
        #expect(!coverage.isPartial)
        #expect(coverage.serverMessages == nil)
        #expect(coverage.oldest == nil && coverage.newest == nil)
        #expect(!coverage.isStale())
    }

    @Test func anIndexShorterThanTheServerIsPartial() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        addMessages(10, from: "a@x.example", to: account, in: context)
        snapshot(account, onServer: 25, indexedAt: .now, in: context)
        try context.save()

        let coverage = try IndexCoverage.current(for: account, in: context)
        #expect(coverage.indexedMessages == 10)
        #expect(coverage.serverMessages == 25)
        #expect(coverage.isPartial)
        let oldest = try #require(coverage.oldest), newest = try #require(coverage.newest)
        #expect(oldest < newest)
    }

    @Test func coverageDatesComeFromSavedHeadersWithoutAProfileRebuild() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        addMessages(3, from: "a@x.example", to: account, in: context)
        try context.save()
        #expect(SenderProfileBuilder.profiles(for: account, in: context).isEmpty)

        let coverage = try IndexCoverage.current(for: account, in: context)
        #expect(coverage.indexedMessages == 3)
        let oldest = try #require(coverage.oldest), newest = try #require(coverage.newest)
        #expect(oldest < newest)
    }

    @Test func aFullIndexIsNotPartial() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        addMessages(10, from: "a@x.example", to: account, in: context)
        snapshot(account, onServer: 10, indexedAt: .now, in: context)
        try context.save()
        #expect(try !IndexCoverage.current(for: account, in: context).isPartial)
    }

    @Test func coverageIsStaleOnlyAfterTheThreshold() {
        let now = Date()
        func coverage(daysAgo: Int) -> IndexCoverage {
            IndexCoverage(indexedMessages: 1, serverMessages: 1, oldest: nil, newest: nil,
                          lastIndexedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now))
        }
        #expect(!coverage(daysAgo: IndexCoverage.staleAfterDays).isStale(now: now))
        #expect(coverage(daysAgo: IndexCoverage.staleAfterDays + 1).isStale(now: now))
    }

    @Test func coverageDoesNotCountAnotherAccount() throws {
        let c = try container(); let context = c.mainContext
        let first = account("a", in: context), second = account("b", in: context)
        addMessages(4, from: "a@x.example", to: first, in: context)
        addMessages(9, from: "a@x.example", to: second, in: context)
        snapshot(second, onServer: 9, indexedAt: .now, in: context)
        try context.save()
        let coverage = try IndexCoverage.current(for: first, in: context)
        #expect(coverage.indexedMessages == 4)
        #expect(coverage.serverMessages == nil)
    }

    // MARK: Sender counts

    @Test func inboxAndOutOfInboxCountsAddUpToIndexed() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        addMessages(20, from: "bulk@x.example", to: account, inboxEvery: 4, in: context)
        try context.save()
        try SenderProfileBuilder.rebuild(for: account, in: context)

        let profile = try #require(SenderProfileBuilder.profiles(for: account, in: context).first)
        let evidence = SenderEvidence(profile: profile, rule: nil, allProfiles: [profile])
        #expect(evidence.indexed == 20)
        #expect(evidence.inInbox == 5)
        #expect(evidence.outOfInbox == 15)
        #expect(evidence.inInbox + evidence.outOfInbox == evidence.indexed)
        #expect(evidence.ruleSummary == nil)
        #expect(evidence.otherAccounts.isEmpty)
    }

    @Test func inboxCountAgreesWithTheCleanupPlanAndGuardForTheSameScope() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        addMessages(30, from: "news@promo.example", name: "Promo", to: account, inboxEvery: 2, in: context)
        try context.save()
        try SenderProfileBuilder.rebuild(for: account, in: context)

        let profile = try #require(SenderProfileBuilder.profiles(for: account, in: context).first)
        let evidence = SenderEvidence(profile: profile, rule: nil, allProfiles: [profile])
        var plan = CleanupPlan(items: [CleanupPlan.Item(cluster: profile.cluster)])
        #expect(plan.items.first?.messageCount == evidence.inInbox)

        let accountID = account.id
        let headers = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == accountID }))
        plan.previewGuard(policy: .gentle) { cluster in
            headers.filter { cluster.pendingUIDs.contains($0.uid) }
                .map { .init(uid: $0.uid, subject: $0.subject, isFlagged: $0.isFlagged, importance: $0.importance, receivedAt: $0.receivedAt) }
        }
        let item = try #require(plan.items.first)
        #expect((item.guardedCount ?? 0) + item.heldCount == evidence.inInbox)
    }

    @Test func aRuleIsReportedWithEveryOtherAccountItReaches() throws {
        let c = try container(); let context = c.mainContext
        let home = account("home", in: context), work = account("work", in: context)
        addMessages(6, from: "shared@x.example", to: home, in: context)
        addMessages(12, from: "shared@x.example", to: work, in: context)
        try context.save()
        try SenderProfileBuilder.rebuild(for: home, in: context)
        try SenderProfileBuilder.rebuild(for: work, in: context)

        let all = try context.fetch(FetchDescriptor<SenderProfile>())
        let profile = try #require(all.first { $0.accountID == home.id })
        let rule = SenderRule(address: "shared@x.example", decision: .sweep)
        let evidence = SenderEvidence(profile: profile, rule: rule, allProfiles: all)
        #expect(evidence.ruleSummary == rule.summary)
        #expect(evidence.otherAccounts == [.init(accountID: work.id, messageCount: 12)])
    }

    @Test func longAndNonLatinNamesAreNotAltered() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        let name = "株式会社サンプル通販ニュースレター配信センター " + String(repeating: "とても長い名前", count: 12)
        addMessages(3, from: "jp@x.example", name: name, to: account, in: context)
        try context.save()
        try SenderProfileBuilder.rebuild(for: account, in: context)
        let profile = try #require(SenderProfileBuilder.profiles(for: account, in: context).first)
        #expect(profile.displayName == name)
        #expect(SenderEvidence(profile: profile, rule: nil, allProfiles: [profile]).indexed == 3)
    }

    // MARK: Wording and the sweep preview

    @Test func coverageCaptionSaysWhatTheIndexCovers() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func caption(indexed: Int, server: Int?, daysAgo: Int?, dated: Bool = true) -> String {
            IndexCoverage(indexedMessages: indexed, serverMessages: server,
                          oldest: dated ? now.addingTimeInterval(-400 * 86_400) : nil, newest: dated ? now : nil,
                          lastIndexedAt: daysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) })
                .caption(now: now, calendar: Calendar(identifier: .gregorian))
        }
        #expect(caption(indexed: 0, server: nil, daysAgo: nil) == "Nothing indexed yet")
        let partial = caption(indexed: 4_812, server: 6_030, daysAgo: 9)
        #expect(partial.hasPrefix("Index covers \(4_812.formatted()) of \(6_030.formatted()) messages · partial · "))
        #expect(partial.hasSuffix("Updated 9 days ago, may be out of date"))
        let full = caption(indexed: 10, server: 10, daysAgo: 0)
        #expect(full.hasPrefix("Index covers all 10 messages"))
        #expect(full.hasSuffix("Updated today"))
        #expect(caption(indexed: 10, server: 10, daysAgo: 1).hasSuffix("Updated yesterday"))
        #expect(!caption(indexed: 10, server: 10, daysAgo: 7).contains("out of date"))
        #expect(caption(indexed: 3, server: nil, daysAgo: nil, dated: false) == "Index covers 3 messages")
        #expect(caption(indexed: 0, server: 40, daysAgo: 2, dated: false) == "Nothing indexed yet · the server reports 40 messages")
        #expect(caption(indexed: 12, server: 10, daysAgo: 0).hasPrefix("Index covers 12 messages · the server now reports 10 · "))
    }

    @Test func sweepNowMatchesThePlanAndGuardAndWritesNothing() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        addMessages(30, from: "news@promo.example", name: "Promo", to: account, inboxEvery: 2, in: context)
        try context.save()
        try SenderProfileBuilder.rebuild(for: account, in: context)
        let profile = try #require(SenderProfileBuilder.profiles(for: account, in: context).first)

        let outcome = try #require(try SenderEvidence.sweepNow(address: profile.address, accountID: account.id, rule: nil, policy: .gentle, in: context))
        guard case .sweeps(let sweep) = outcome else { Issue.record("expected a sweep, got \(outcome)"); return }
        #expect(sweep.affectedCount + sweep.heldCount == SenderEvidence(profile: profile, rule: nil, allProfiles: [profile]).inInbox)
        #expect(try context.fetch(FetchDescriptor<SenderRule>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CleanupAction>()).isEmpty)
    }

    @Test func sweepNowReportsAKeepRuleAndAnEmptyInbox() throws {
        let c = try container(); let context = c.mainContext
        let account = account("a", in: context)
        addMessages(4, from: "keep@x.example", to: account, in: context)
        addMessages(4, from: "done@x.example", to: account, inboxEvery: 1_000_000, firstUID: 100, in: context)
        for header in try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.senderAddress == "done@x.example" })) {
            header.isInInbox = false
        }
        try context.save()
        try SenderProfileBuilder.rebuild(for: account, in: context)

        let keep = SenderRule(address: "keep@x.example", decision: .keep)
        context.insert(keep)
        try context.save()
        let kept = try SenderEvidence.sweepNow(address: "keep@x.example", accountID: account.id, rule: keep, policy: .gentle, in: context)
        #expect(kept == .keptInInbox)
        #expect(SweepNowText(.keptInInbox).moves == "Your rule keeps this sender in the inbox. Nothing moves.")

        let done = try SenderEvidence.sweepNow(address: "done@x.example", accountID: account.id, rule: nil, policy: .gentle, in: context)
        #expect(done == .nothingPending)
    }

    @Test func sweepWordingCountsAndNamesWhereMailGoes() {
        func sweep(moves: Int, held: Int) -> RulePreview.Outcome {
            .sweeps(.init(disposition: .fileIntoFolders, folder: "Promotions", markRead: false, unsubscribe: false,
                          affectedCount: moves, heldCount: held, affectedUIDs: [], heldUIDs: [], affected: [],
                          held: held == 0 ? [] : [.init(uid: 1, subject: "Receipt #4471", receivedAt: .now, heldReason: "looks like a receipt")]))
        }
        #expect(SweepNowText(sweep(moves: 27, held: 4)).moves == "Moves 27 messages to Promotions.")
        #expect(SweepNowText(sweep(moves: 1, held: 0)).moves == "Moves 1 message to Promotions.")
        #expect(SweepNowText(sweep(moves: 0, held: 0)).moves == "Nothing would move.")
        let text = SweepNowText(sweep(moves: 27, held: 4))
        #expect(text.held == "4 stay in the inbox.")
        #expect(text.heldDetails == ["Receipt #4471: looks like a receipt"])
        #expect(SweepNowText(sweep(moves: 3, held: 0)).held == nil)

        let many = RulePreview.Outcome.sweeps(.init(
            disposition: .archiveOnly, folder: "", markRead: false, unsubscribe: false, affectedCount: 0, heldCount: 5,
            affectedUIDs: [], heldUIDs: [], affected: [],
            held: (1...5).map { .init(uid: UInt32($0), subject: "Subject \($0)", receivedAt: .now, heldReason: "flagged") }))
        #expect(SweepNowText(many).heldDetails.count == 3)
        #expect(SweepNowText(many).held == "5 stay in the inbox.")
    }

    @Test func scopeNamesTheOtherAccountsAndSaysRulesAreGlobal() throws {
        let c = try container(); let context = c.mainContext
        let home = account("home", in: context), work = account("work", in: context)
        addMessages(6, from: "shared@x.example", to: home, in: context)
        addMessages(12, from: "shared@x.example", to: work, in: context)
        try context.save()
        try SenderProfileBuilder.rebuild(for: home, in: context)
        try SenderProfileBuilder.rebuild(for: work, in: context)
        let all = try context.fetch(FetchDescriptor<SenderProfile>())
        let profile = try #require(all.first { $0.accountID == home.id })

        let none = SenderEvidence(profile: profile, rule: nil, allProfiles: all).scope(accountNames: [home.id: "home", work.id: "work"])
        #expect(none == "No rule yet. A rule applies to this address in every account. Also seen in work (12 messages).")
        let rule = SenderRule(address: "shared@x.example", decision: .keep)
        let ruled = SenderEvidence(profile: profile, rule: rule, allProfiles: all).scope(accountNames: [:])
        #expect(ruled.hasPrefix("Rule: Always keep. It applies to this address in every account."))
        #expect(ruled.hasSuffix("Also seen in another account (12 messages)."))
    }

    // MARK: Last sweep

    private let home = UUID()

    private func report(ending: SweepReport.Ending, on accountID: UUID? = nil, _ senders: SweepReport.Sender...) -> SweepReport {
        SweepReport(senders: senders, ending: ending, accountID: accountID ?? home)
    }

    private func text(_ report: SweepReport, address: String = "a@x.example", mailbox: String = "INBOX", account: UUID? = nil) -> LastSweepText {
        LastSweepText(report: report, address: address, mailbox: mailbox, accountID: account ?? home)
    }

    @Test func lastSweepKeepsConfirmedFailedHeldAndUnknownApart() {
        let cutOff = SweepReport.Sender(address: "a@x.example", mailbox: "INBOX", planned: [1, 2, 3, 4], held: [4], steps: 1,
                                        writes: [.init(requested: [1, 2, 3], confirmed: [1, 2], cutOff: true)])
        let interrupted = text(report(ending: .interrupted, cutOff))
        #expect(interrupted.counts.map(\.value) == [2, 0, 1, 1])
        #expect(interrupted.counts.map(\.label) == ["confirmed moved", "failed", "held in the inbox", "unknown"])
        #expect(interrupted.note == "The connection broke off before the sweep finished.")

        let refused = SweepReport.Sender(address: "a@x.example", mailbox: "INBOX", planned: [1, 2], steps: 1,
                                         writes: [.init(requested: [1, 2], confirmed: [])])
        #expect(text(report(ending: .refused, refused)).counts.map(\.value) == [0, 2, 0, 0])

        let done = SweepReport.Sender(address: "a@x.example", mailbox: "INBOX", planned: [1, 2], steps: 1,
                                      writes: [.init(requested: [1, 2], confirmed: [1, 2])])
        let ok = text(report(ending: .completed, done))
        #expect(ok.counts.map(\.value) == [2, 0, 0, 0])
        #expect(ok.note == nil)
        #expect(ok.counts.map(\.value).reduce(0, +) == done.planned.count)
    }

    @Test func lastSweepAddsEveryEntryForTheSameSenderWithoutHidingAFailure() {
        func entry(_ uid: UInt32, confirmed: Bool) -> SweepReport.Sender {
            SweepReport.Sender(address: "a@x.example", mailbox: "INBOX", planned: [uid], steps: 1,
                               writes: [.init(requested: [uid], confirmed: confirmed ? [uid] : [])])
        }
        let thread = report(ending: .completed, entry(1, confirmed: true), entry(2, confirmed: true), entry(3, confirmed: false))
        #expect(text(thread).counts.map(\.value) == [2, 1, 0, 0])
    }

    @Test func lastSweepIsShownOnlyForTheAccountItRanOn() {
        let sender = SweepReport.Sender(address: "a@x.example", mailbox: "INBOX", planned: [1], steps: 1,
                                        writes: [.init(requested: [1], confirmed: [1])])
        let completed = report(ending: .completed, sender)
        #expect(text(completed).counts.map(\.value) == [1, 0, 0, 0])
        let elsewhere = text(completed, account: UUID())
        #expect(elsewhere.counts.isEmpty)
        #expect(elsewhere.note == "The last sweep ran on a different account.")
        let unattributed = text(SweepSummaryWithoutAccount(sender))
        #expect(unattributed.counts.isEmpty)
        #expect(text(SweepReport()).note == "No sweep has run since Grokbox opened.")
    }

    @Test func lastSweepSaysSoWhenThereIsNothingToCount() {
        let sender = SweepReport.Sender(address: "a@x.example", mailbox: "INBOX", planned: [1])
        let completed = report(ending: .completed, sender)
        let other = text(completed, address: "b@x.example")
        #expect(other.counts.isEmpty)
        #expect(other.note == "This sender was not in the last sweep.")
        #expect(text(completed, mailbox: "Archive").counts.isEmpty)
        let running = text(report(ending: .running, sender))
        #expect(running.counts.isEmpty)
        #expect(running.note == "A sweep is running now.")
    }

    @Test func lastSweepNotesAStopAndARefusal() {
        let sender = SweepReport.Sender(address: "a@x.example", mailbox: "INBOX", planned: [1])
        let stopped = text(report(ending: .stopped, sender))
        #expect(stopped.counts.map(\.value) == [0, 0, 0, 1])
        #expect(stopped.note == "The sweep was stopped before it finished.")
        let refused = text(report(ending: .refused, sender))
        #expect(refused.counts.map(\.value) == [0, 1, 0, 0])
        #expect(refused.note == "The sweep was refused before it finished.")
    }
}

private func SweepSummaryWithoutAccount(_ sender: SweepReport.Sender) -> SweepReport {
    SweepReport(senders: [sender], ending: .completed)
}
