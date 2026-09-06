import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

@MainActor
@Suite(.serialized)
struct SenderProfileTests {
    private func container() throws -> ModelContainer {
        let schema = Schema([MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self, SenderRule.self, MailboxSnapshot.self, SenderProfile.self, InboxDigest.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func seed(_ context: ModelContext, senders: Int, perSender: Int) throws -> MailAccount {
        let account = MailAccount(displayName: "A", username: "a@x", host: "h", port: 1, kind: .generic, security: .tls)
        context.insert(account)
        var uid: UInt32 = 0
        for s in 0..<senders {
            let address = "sender\(s)@x.example"
            for m in 0..<perSender {
                uid += 1
                let message = MessageHeader(
                    accountID: account.id, uid: uid, mailbox: "INBOX", subject: "Subject \(m)", senderName: "Sender \(s)", senderAddress: address,
                    receivedAt: Date(timeIntervalSinceNow: -Double(m) * 3600), isUnread: m % 3 != 0, isFlagged: false,
                    listUnsubscribe: s % 2 == 0 ? "<https://x.example/u>" : nil, listUnsubscribePost: nil, listID: nil, messageID: nil,
                    isInInbox: m % 5 != 0
                )
                context.insert(message)
                // A context holding tens of thousands of unsaved inserts slows to a
                // crawl; flush as a real index pass would.
                if uid % 2_000 == 0 { try context.save() }
            }
        }
        context.insert(ContactedAddress(address: "sender1@x.example", lastContactedAt: .now))
        try context.save()
        return account
    }

    @Test func profilesMatchTheInMemoryClustering() throws {
        let c = try container(); let context = c.mainContext
        let account = try seed(context, senders: 12, perSender: 25)

        let count = try SenderProfileBuilder.rebuild(for: account, in: context)
        #expect(count == 12)

        let id = account.id
        let messages = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id }))
        let reference = HeuristicAnalyzer().assess(SenderClusterBuilder.build(messages: messages, contactedAddresses: ["sender1@x.example"]))
        let profiles = SenderProfileBuilder.assessments(for: account, in: context)

        for ref in reference {
            let prof = try #require(profiles.first { $0.cluster.address == ref.cluster.address })
            #expect(prof.cluster.messageCount == ref.cluster.messageCount)
            #expect(prof.cluster.unreadCount == ref.cluster.unreadCount)
            #expect(Set(prof.cluster.pendingUIDs) == Set(ref.cluster.pendingUIDs))
            #expect(prof.verdict == ref.verdict, "\(ref.cluster.address)")
            #expect(prof.score == ref.score)
            #expect(prof.cluster.everContacted == ref.cluster.everContacted)
            #expect(prof.cluster.hasUnsubscribeLink == ref.cluster.hasUnsubscribeLink)
            #expect(prof.cluster.sampleSubjects.count == min(3, ref.cluster.messageCount))
        }
    }

    @Test func rebuildIsIdempotentAndDropsStaleSenders() throws {
        let c = try container(); let context = c.mainContext
        let account = try seed(context, senders: 5, perSender: 4)
        try SenderProfileBuilder.rebuild(for: account, in: context)
        try SenderProfileBuilder.rebuild(for: account, in: context)
        #expect(try context.fetchCount(FetchDescriptor<SenderProfile>()) == 5, "no duplicates")

        let id = account.id
        for message in try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id && $0.senderAddress == "sender0@x.example" })) {
            context.delete(message)
        }
        try context.save()
        try SenderProfileBuilder.rebuild(for: account, in: context)
        #expect(try context.fetchCount(FetchDescriptor<SenderProfile>()) == 4, "stale profile removed")
    }

    @Test func adjustTracksSweepAndUndoWithoutRescan() throws {
        let c = try container(); let context = c.mainContext
        let account = try seed(context, senders: 2, perSender: 10)
        try SenderProfileBuilder.rebuild(for: account, in: context)
        let before = try #require(SenderProfileBuilder.profiles(for: account, in: context).first { $0.address == "sender0@x.example" })
        let pending = before.pendingUIDs
        #expect(pending.count == 8)

        SenderProfileBuilder.adjust(accountID: account.id, address: "sender0@x.example", uids: pending, swept: true, in: context)
        #expect(before.pendingUIDs.isEmpty)
        #expect(before.sweptCount == 8)

        SenderProfileBuilder.adjust(accountID: account.id, address: "sender0@x.example", uids: Array(pending.prefix(3)), swept: false, in: context)
        #expect(before.pendingUIDs.count == 3)
        #expect(before.sweptCount == 5)
    }

    /// The reason this layer exists. 40,000 headers must aggregate in seconds,
    /// not minutes, and the resulting query the UI runs must be tiny.
    @Test func fortyThousandMessagesRebuildQuickly() throws {
        let c = try container(); let context = c.mainContext
        let clock = ContinuousClock()
        var account: MailAccount!
        let seedTime = try clock.measure { account = try seed(context, senders: 400, perSender: 100) }
        print("PERF seeding 40k messages took \(seedTime)")

        let elapsed = try clock.measure {
            try SenderProfileBuilder.rebuild(for: account, in: context)
        }
        let profiles = try context.fetchCount(FetchDescriptor<SenderProfile>())
        #expect(profiles == 400)
        #expect(elapsed < .seconds(15), "rebuild of 40k took \(elapsed)")

        let queryTime = clock.measure {
            _ = SenderProfileBuilder.assessments(for: account, in: context)
        }
        #expect(queryTime < .seconds(1), "UI-facing query took \(queryTime)")

        // Second rebuild (the common case: profiles already exist) should be no slower.
        let again = try clock.measure {
            try SenderProfileBuilder.rebuild(for: account, in: context)
        }
        #expect(again < .seconds(15))
        print("PERF 40k messages → 400 profiles: rebuild \(elapsed), re-rebuild \(again), UI query \(queryTime)")
    }
}
