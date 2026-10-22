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
}
