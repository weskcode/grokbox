import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

struct HeuristicAnalyzerTests {
    private func cluster(
        address: String,
        count: Int,
        unread: Int,
        unsubscribe: Bool,
        contacted: Bool,
        flagged: Int = 0,
        newest: Date = .now
    ) -> SenderCluster {
        SenderCluster(
            address: address, displayName: address, domain: "x.example", mailbox: "INBOX",
            uids: Array(1...UInt32(max(count, 1))), unreadUIDs: [], messageCount: count, unreadCount: unread,
            flaggedCount: flagged, sweptCount: 0, newest: newest, oldest: newest,
            hasUnsubscribeLink: unsubscribe, unsubscribeValue: unsubscribe ? "<https://x.example/u>" : nil,
            supportsOneClickUnsubscribe: false, everContacted: contacted, sampleSubjects: []
        )
    }

    @Test func newsletterYouNeverOpenIsBulk() {
        let result = HeuristicAnalyzer().assess([cluster(address: "news@x.example", count: 40, unread: 39, unsubscribe: true, contacted: false)])
        #expect(result[0].verdict == .bulk)
    }

    @Test func someoneYouWriteToIsKeptEvenIfTheyLookBulk() {
        let result = HeuristicAnalyzer().assess([cluster(address: "friend@x.example", count: 40, unread: 39, unsubscribe: true, contacted: true)])
        #expect(result[0].verdict == .keep, "contact signal outweighs every bulk signal")
    }

    @Test func flaggedMailIsKept() {
        let result = HeuristicAnalyzer().assess([cluster(address: "a@x.example", count: 5, unread: 5, unsubscribe: true, contacted: false, flagged: 1)])
        #expect(result[0].verdict != .bulk)
    }

    @Test func sortsBulkFirst() {
        let result = HeuristicAnalyzer().assess([
            cluster(address: "friend@x.example", count: 3, unread: 0, unsubscribe: false, contacted: true),
            cluster(address: "news@x.example", count: 40, unread: 39, unsubscribe: true, contacted: false),
        ])
        #expect(result.first?.cluster.address == "news@x.example")
    }
}

@MainActor
struct ImportanceScorerTests {
    private func container() throws -> ModelContainer {
        let schema = Schema([MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self, SenderProfile.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func message(uid: UInt32, from: String, unread: Bool = true, flagged: Bool = false, daysAgo: Int = 1) -> MessageHeader {
        MessageHeader(
            accountID: UUID(), uid: uid, mailbox: "INBOX", subject: "s", senderName: "", senderAddress: from,
            receivedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            isUnread: unread, isFlagged: flagged,
            listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil, messageID: nil
        )
    }

    @Test func bulkSendersSkipTheModel() throws {
        _ = try container()
        let candidates = ImportanceScorer.candidates(
            in: [message(uid: 1, from: "news@x.example")],
            verdictFor: { _ in .bulk },
            contacted: []
        )
        #expect(candidates.count == 1)
        #expect(candidates[0].skipModel)
        #expect(candidates[0].baseline == .noise)
    }

    @Test func unreadMailFromAContactNeedsYou() throws {
        _ = try container()
        let candidates = ImportanceScorer.candidates(
            in: [message(uid: 1, from: "alice@x.example")],
            verdictFor: { _ in .keep },
            contacted: ["alice@x.example"]
        )
        #expect(candidates[0].skipModel == false)
        #expect(candidates[0].baseline == .needsYou)
    }

    @Test func oldMailIsOutsideTheWindow() throws {
        _ = try container()
        let candidates = ImportanceScorer.candidates(
            in: [message(uid: 1, from: "alice@x.example", daysAgo: 90)],
            verdictFor: { _ in .keep },
            contacted: []
        )
        #expect(candidates.isEmpty)
    }

    @Test func modelBudgetIsCapped() throws {
        _ = try container()
        let messages = (1...300).map { message(uid: UInt32($0), from: "p\($0)@x.example") }
        let candidates = ImportanceScorer.candidates(in: messages, verdictFor: { _ in .review }, contacted: [], limit: 50)
        #expect(candidates.filter { !$0.skipModel }.count == 50)
    }
}

struct CleanupPlanTests {
    @Test func suggestedPlanIsBulkOnly() {
        let bulk = SenderCluster(address: "b@x", displayName: "b", domain: "x", mailbox: "m", uids: [1, 2], unreadUIDs: [1, 2], messageCount: 2, unreadCount: 2, flaggedCount: 0, sweptCount: 0, newest: .now, oldest: .now, hasUnsubscribeLink: true, unsubscribeValue: nil, supportsOneClickUnsubscribe: false, everContacted: false, sampleSubjects: [])
        let keep = SenderCluster(address: "k@x", displayName: "k", domain: "x", mailbox: "m", uids: [3], unreadUIDs: [], messageCount: 1, unreadCount: 0, flaggedCount: 0, sweptCount: 0, newest: .now, oldest: .now, hasUnsubscribeLink: false, unsubscribeValue: nil, supportsOneClickUnsubscribe: false, everContacted: true, sampleSubjects: [])
        let plan = CleanupPlan.suggested(from: [
            SenderAssessment(cluster: bulk, verdict: .bulk, score: 5, reasons: []),
            SenderAssessment(cluster: keep, verdict: .keep, score: -6, reasons: []),
        ])
        #expect(plan.items.map(\.id) == ["b@x"])
        #expect(plan.enabledMessageCount == 2)
    }
}

struct UnsubscribeTests {
    @Test func prefersHTTPSTarget() {
        let cluster = SenderCluster(address: "a@x", displayName: "", domain: "", mailbox: "", uids: [], unreadUIDs: [], messageCount: 0, unreadCount: 0, flaggedCount: 0, sweptCount: 0, newest: .now, oldest: .now, hasUnsubscribeLink: true, unsubscribeValue: "<mailto:u@x.example>, <https://x.example/unsub>", supportsOneClickUnsubscribe: true, everContacted: false, sampleSubjects: [])
        #expect(cluster.unsubscribeURL?.absoluteString == "https://x.example/unsub")
    }

    @Test func mailtoOnlyIsReportedNotSent() async {
        let cluster = SenderCluster(address: "a@x", displayName: "", domain: "", mailbox: "", uids: [], unreadUIDs: [], messageCount: 0, unreadCount: 0, flaggedCount: 0, sweptCount: 0, newest: .now, oldest: .now, hasUnsubscribeLink: true, unsubscribeValue: "<mailto:u@x.example>", supportsOneClickUnsubscribe: false, everContacted: false, sampleSubjects: [])
        let outcome = await UnsubscribeService.unsubscribe(from: cluster)
        #expect(outcome == .requiresEmail("mailto:u@x.example"))
    }
}

struct SanitizerTests {
    @Test func stripsLeakedLabels() {
        #expect(ReaderPrompt.sanitize("Review PR blocking release branch. Must review. NeedsYou") == "Review PR blocking release branch. Must review.")
        #expect(ReaderPrompt.sanitize("Confirm lunch plan by Friday? Yes, respond. (Action needed.)") == "Confirm lunch plan by Friday? Yes, respond.")
        #expect(ReaderPrompt.sanitize("daily standup starts in 10 minutes; respond in JSON.") == "Daily standup starts in 10 minutes;.")
        #expect(ReaderPrompt.sanitize("  Alice asks about lunch  ") == "Alice asks about lunch.")
    }
}
