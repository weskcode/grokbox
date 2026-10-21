import Foundation
import SwiftData
import Testing
@testable import GrokboxCore

/// The store shape every install had before reply ids and Sent headers: a copy
/// of the eight 1.1.0 models, so an old store can be written for real
/// (ADR-0021). Only stored properties matter here.
enum GrokboxSchemaV1_1_0: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 1, 0) }
    static var models: [any PersistentModel.Type] {
        [MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self,
         SenderRule.self, MailboxSnapshot.self, SenderProfile.self, InboxDigest.self]
    }

    @Model final class MailAccount {
        #Index<MailAccount>([\.username])
        var id: UUID = UUID()
        var displayName: String = ""
        var username: String = ""
        var host: String = ""
        var port: Int = 993
        var kindRaw: String = "generic"
        var securityRaw: String = "tls"
        var createdAt: Date = Date()
        var lastSyncedAt: Date?
        var lastReadAt: Date?
        var lastSyncError: String?
        init(username: String) { self.username = username; self.displayName = username }
    }

    @Model final class MessageHeader {
        #Index<MessageHeader>([\.accountID], [\.senderAddress], [\.receivedAt], [\.importanceRaw], [\.briefRank], [\.accountID, \.senderAddress], [\.subject])
        var accountID: UUID = UUID()
        var uid: UInt32 = 0
        var mailbox: String = ""
        var subject: String = ""
        var senderName: String = ""
        var senderAddress: String = ""
        var senderDomain: String = ""
        var receivedAt: Date = Date.distantPast
        var isUnread: Bool = true
        var isFlagged: Bool = false
        var listUnsubscribe: String?
        var listUnsubscribePost: String?
        var listID: String?
        var messageID: String?
        var isSweptLocally: Bool = false
        var isInInbox: Bool = true
        var summary: String?
        var importanceRaw: String?
        var importanceReason: String?
        var readAt: Date?
        var briefRank: Int = 0
        var actionTypeRaw: String = "none"
        var dueHint: String?
        var dueAt: Date?
        var isQuick: Bool = false
        var snoozedUntil: Date?
        init(accountID: UUID, uid: UInt32, subject: String, senderAddress: String, messageID: String?) {
            self.accountID = accountID; self.uid = uid; self.mailbox = "INBOX"; self.subject = subject
            self.senderAddress = senderAddress; self.messageID = messageID
        }
    }

    @Model final class ContactedAddress {
        @Attribute(.unique) var address: String = ""
        var lastContactedAt: Date = Date.distantPast
        var timesContacted: Int = 0
        init(address: String) { self.address = address; self.timesContacted = 1 }
    }

    @Model final class CleanupAction {
        var id: UUID = UUID()
        var accountID: UUID = UUID()
        var performedAt: Date = Date()
        var kindRaw: String = "archive"
        var senderAddress: String = ""
        var senderName: String = ""
        var mailbox: String = ""
        var uids: [UInt32] = []
        var labelName: String?
        var isUndoable: Bool = true
        var undoneAt: Date?
        var errorMessage: String?
        var uidValidity: UInt32 = 0
        var targetMailbox: String?
        var targetUIDs: [UInt32] = []
        var targetUIDValidity: UInt32 = 0
        var heldUIDs: [UInt32] = []
        var heldSummary: String?
        init(accountID: UUID, kindRaw: String, senderAddress: String, uids: [UInt32]) {
            self.accountID = accountID; self.kindRaw = kindRaw; self.senderAddress = senderAddress; self.uids = uids
        }
    }

    @Model final class SenderRule {
        @Attribute(.unique) var address: String = ""
        var decisionRaw: String = "sweep"
        var createdAt: Date = Date()
        var timesApplied: Int = 0
        var dispositionRaw: String?
        var autoUnsubscribeOverride: Bool?
        var customFolder: String?
        init(address: String, decisionRaw: String) { self.address = address; self.decisionRaw = decisionRaw }
    }

    @Model final class MailboxSnapshot {
        @Attribute(.unique) var key: String = ""
        var accountID: UUID = UUID()
        var mailbox: String = ""
        var uidValidity: UInt32 = 0
        var highestUID: UInt32 = 0
        var messageCountOnServer: Int = 0
        var lastIndexedAt: Date = Date()
        init(key: String) { self.key = key }
    }

    @Model final class SenderProfile {
        @Attribute(.unique) var key: String = ""
        #Index<SenderProfile>([\.accountID], [\.verdictRaw])
        var accountID: UUID = UUID()
        var address: String = ""
        var displayName: String = ""
        var domain: String = ""
        var mailbox: String = ""
        var messageCount: Int = 0
        var unreadCount: Int = 0
        var flaggedCount: Int = 0
        var sweptCount: Int = 0
        var pendingUIDs: [UInt32] = []
        var newest: Date = Date.distantPast
        var oldest: Date = Date.distantPast
        var hasUnsubscribeLink: Bool = false
        var unsubscribeValue: String?
        var supportsOneClickUnsubscribe: Bool = false
        var everContacted: Bool = false
        var sampleSubjects: [String] = []
        var score: Int = 0
        var verdictRaw: String = "review"
        var reasons: [String] = []
        var categoryRaw: String = "unknown"
        var categoryEvidence: String = ""
        var categoryConfident: Bool = false
        var categoryFromModel: Bool = false
        var recommendationRaw: String = "review"
        var recommendationReason: String = ""
        var updatedAt: Date = Date()
        init(key: String) { self.key = key }
    }

    @Model final class InboxDigest {
        #Index<InboxDigest>([\.generatedAt], [\.scopeKey])
        var id: UUID = UUID()
        var generatedAt: Date = Date()
        var scopeKey: String = "all"
        var scopeLabel: String = ""
        var headline: String = ""
        var narrative: String = ""
        var topItems: [DigestItem] = []
        var needsYou: Int = 0
        var worthKnowing: Int = 0
        var dueSoon: Int = 0
        var overdue: Int = 0
        var quickWins: Int = 0
        var unreadUnclassified: Int = 0
        var sweptToday: Int = 0
        var heldToday: Int = 0
        var pendingBulkSenders: Int = 0
        var pendingBulkMessages: Int = 0
        var unsubscribeCandidates: Int = 0
        var inboxNow: Int = 0
        init(headline: String) { self.headline = headline }
    }
}

struct ConversationStoreTests {
    @Test func aStoreWrittenByTheOldShapeOpensWithRulesAndHistoryIntact() throws {
        let directory = URL.temporaryDirectory.appending(path: "grokbox-v110-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "default.store")
        let account = UUID()

        do {
            let old = Schema(versionedSchema: GrokboxSchemaV1_1_0.self)
            let container = try ModelContainer(for: old, configurations: ModelConfiguration(schema: old, url: url))
            let context = ModelContext(container)
            context.insert(GrokboxSchemaV1_1_0.MailAccount(username: "old@example.com"))
            context.insert(GrokboxSchemaV1_1_0.MessageHeader(accountID: account, uid: 7, subject: "Lunch", senderAddress: "alice@friend.example", messageID: "<a0@friend.example>"))
            context.insert(GrokboxSchemaV1_1_0.MessageHeader(accountID: account, uid: 8, subject: "Re: Lunch", senderAddress: "bob@else.example", messageID: "<b1@else.example>"))
            let trash = GrokboxSchemaV1_1_0.SenderRule(address: "deals@x.example", decisionRaw: "sweep")
            trash.dispositionRaw = "trash"
            trash.autoUnsubscribeOverride = false
            context.insert(trash)
            context.insert(GrokboxSchemaV1_1_0.SenderRule(address: "mum@family.example", decisionRaw: "keep"))
            let moved = GrokboxSchemaV1_1_0.CleanupAction(accountID: account, kindRaw: "archive", senderAddress: "deals@x.example", uids: [3, 4])
            moved.uidValidity = 11
            moved.targetMailbox = "Archive"
            moved.targetUIDs = [90, 91]
            moved.targetUIDValidity = 12
            context.insert(moved)
            let undone = GrokboxSchemaV1_1_0.CleanupAction(accountID: account, kindRaw: "markRead", senderAddress: "news@n.example", uids: [5])
            undone.undoneAt = Date(timeIntervalSince1970: 1_800_000_000)
            context.insert(undone)
            context.insert(GrokboxSchemaV1_1_0.ContactedAddress(address: "alice@friend.example"))
            context.insert(GrokboxSchemaV1_1_0.MailboxSnapshot(key: "\(account.uuidString)|INBOX"))
            context.insert(GrokboxSchemaV1_1_0.SenderProfile(key: "\(account.uuidString)|deals@x.example"))
            context.insert(GrokboxSchemaV1_1_0.InboxDigest(headline: "Two things"))
            try context.save()
        }

        let schema = Schema(versionedSchema: GrokboxSchemaV1.self)
        let container = try ModelContainer(for: schema, migrationPlan: GrokboxMigrationPlan.self,
                                           configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".unreadable"))

        let rules = try context.fetch(FetchDescriptor<SenderRule>(sortBy: [SortDescriptor(\.address)]))
        #expect(rules.map(\.address) == ["deals@x.example", "mum@family.example"])
        #expect(rules[0].decision == .sweep && rules[0].disposition == .trash && rules[0].autoUnsubscribeOverride == false)
        #expect(rules[1].decision == .keep && rules[1].disposition == nil)

        let actions = try context.fetch(FetchDescriptor<CleanupAction>(sortBy: [SortDescriptor(\.senderAddress)]))
        #expect(actions.count == 2)
        #expect(actions[0].kind == .archive && actions[0].uids == [3, 4] && actions[0].uidValidity == 11)
        #expect(actions[0].targetMailbox == "Archive" && actions[0].targetUIDs == [90, 91] && actions[0].targetUIDValidity == 12)
        #expect(actions[1].kind == .markRead && actions[1].isUndone)

        let messages = try context.fetch(FetchDescriptor<MessageHeader>(sortBy: [SortDescriptor(\.uid)]))
        #expect(messages.map(\.uid) == [7, 8])
        #expect(messages.allSatisfy { $0.inReplyTo == nil && $0.referenceIDs == nil }, "never fetched reads as unknown")
        #expect(try context.fetchCount(FetchDescriptor<MailAccount>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ContactedAddress>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<MailboxSnapshot>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<SenderProfile>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<InboxDigest>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<SentMessageHeader>()) == 0)

        let unknown = BriefRanking.rank(messages, contactCounts: [:])
        #expect(unknown.count == 2, "an upgraded store groups exactly as before until reply ids are fetched")

        messages[1].referenceIDs = MessageIDList.encode(["a0@friend.example"])
        messages[1].inReplyTo = MessageIDList.encode(["a0@friend.example"])
        try context.save()
        #expect(BriefRanking.rank(messages, contactCounts: [:]).count == 1)
    }
}

struct ReplyHeaderStorageTests {
    private func fetched(uid: UInt32, inReplyTo: [String] = [], references: [String] = []) -> FetchedHeader {
        var header = FetchedHeader(uid: uid, subject: "Re: Plan", senderName: "", senderAddress: "me@work.example", recipients: ["alice@friend.example"],
                                   date: Date(timeIntervalSince1970: 1_800_000_000), isUnread: false, isFlagged: false, gmailLabels: nil,
                                   listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil, messageID: "<s\(uid)@work.example>")
        header.inReplyTo = inReplyTo
        header.references = references
        return header
    }

    @Test func idListsRoundTripIncludingQuotedSpaces() {
        let ids = ["a0@friend.example", "\"a b\"@mail.example", "x@y.example"]
        #expect(MessageIDList.decode(MessageIDList.encode(ids)) == ids)
        #expect(MessageIDList.decode("") == [])
        #expect(MessageIDList.decode(nil) == [])
    }

    @Test func replyIDsAreFilledOnceAndNeverReplaced() {
        let message = MessageHeader(accountID: UUID(), uid: 1, mailbox: "INBOX", subject: "Re: Plan", senderName: "", senderAddress: "bob@else.example",
                                    receivedAt: .now, isUnread: true, isFlagged: false, listUnsubscribe: nil, listUnsubscribePost: nil,
                                    listID: nil, messageID: "<b1@else.example>")
        #expect(message.inReplyTo == nil && message.referenceIDs == nil)

        message.recordReplyHeadersIfUnknown(from: fetched(uid: 1))
        #expect(message.inReplyTo == "" && message.referenceIDs == "", "fetched and absent is not unknown")

        message.recordReplyHeadersIfUnknown(from: fetched(uid: 1, inReplyTo: ["a0@friend.example"], references: ["a0@friend.example"]))
        #expect(message.referenceIDs == "", "a known value is not replaced")
    }
}

/// Serves a Sent mailbox and nothing else. It can cancel the task that is
/// walking it at a chosen point, the way Stop does mid-sync.
private struct SentMailbox: MailProvider {
    enum CancelAt { case never, open, lastBatch }
    var uidValidity: UInt32?
    var headers: [FetchedHeader]
    var cancelAt = CancelAt.never

    var capabilities: IMAPCapabilities { IMAPCapabilities(raw: []) }
    func discoverMailboxes() async throws -> [IMAPMailbox] { [] }
    func openReadOnly(_ mailbox: String) async throws -> MailboxStatus {
        if cancelAt == .open { withUnsafeCurrentTask { $0?.cancel() } }
        return MailboxStatus(exists: headers.count, uidValidity: uidValidity)
    }
    func headers(from start: Int, to end: Int) async throws -> [FetchedHeader] {
        if cancelAt == .lastBatch, end >= headers.count { withUnsafeCurrentTask { $0?.cancel() } }
        return Array(headers[(start - 1)..<min(end, headers.count)])
    }
    func headers(uidsFrom start: UInt32) async throws -> [FetchedHeader] { [] }
    func flags(from start: Int, to end: Int) async throws -> [FlagUpdate] { [] }
    func bodyExcerpt(uid: UInt32) async throws -> Data? { nil }
    func waitForNewMail(maxWait: Duration) async throws -> Bool { false }
    func openReadWrite(_ mailbox: String) async throws -> MailboxStatus { throw CancellationError() }
    func setFlags(uids: [UInt32], _ change: IMAPClient.FlagChange, flags: [String]) async throws { throw CancellationError() }
    func setGmailLabels(uids: [UInt32], _ change: IMAPClient.FlagChange, labels: [String]) async throws { throw CancellationError() }
    func move(uids: [UInt32], to mailbox: String) async throws -> MoveResult { throw CancellationError() }
    func ensureMailbox(_ name: String) async throws { throw CancellationError() }
    func finish() async {}
    func abort() async {}
}

@MainActor
struct SentWalkTests {
    private let account = UUID()
    private let sent = IMAPMailbox(name: "Sent", attributes: ["\\Sent"])

    private func header(_ uid: UInt32, to recipient: String = "alice@friend.example") -> FetchedHeader {
        var h = FetchedHeader(uid: uid, subject: "Re: Plan", senderName: "", senderAddress: "me@work.example", recipients: [recipient],
                              date: Date(timeIntervalSince1970: 1_800_000_000), isUnread: false, isFlagged: false, gmailLabels: nil,
                              listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil, messageID: "<s\(uid)@work.example>")
        h.references = ["a0@friend.example"]
        return h
    }

    private func seeded() throws -> ModelContext {
        let context = ModelContext(ModelContainer.grokboxTestContainer())
        for (mailbox, validity, uid) in [("Sent", UInt32(5), UInt32(1)), ("Sent", 5, 2), ("Sent", 5, 7), ("Old Sent", 5, 1)] {
            context.insert(SentMessageHeader(accountID: account, mailbox: mailbox, uidValidity: validity, header: header(uid)))
        }
        context.insert(SentMessageHeader(accountID: UUID(), mailbox: "Sent", uidValidity: 5, header: header(1)))
        try context.save()
        return context
    }

    private func rows(_ context: ModelContext) throws -> [String] {
        try SentHistory.rows(accountID: account, in: context).map { "\($0.mailbox)|\($0.uidValidity)|\($0.uid)" }.sorted()
    }

    private func walk(_ provider: SentMailbox, in context: ModelContext) async -> Bool {
        let engine = SyncEngine(modelContext: context)
        let task = Task { @MainActor in try await engine.walkSent(sent, using: provider, accountID: account) }
        do { try await task.value; return true } catch { return false }
    }

    @Test func aCompletedWalkKeepsExactlyWhatItSaw() async throws {
        let context = try seeded()
        #expect(await walk(SentMailbox(uidValidity: 5, headers: [header(1), header(2), header(3)]), in: context))
        #expect(try rows(context) == ["Sent|5|1", "Sent|5|2", "Sent|5|3"], "UID 7 is gone from the server and the old folder is gone")
        #expect(try context.fetchCount(FetchDescriptor<SentMessageHeader>()) == 4, "another account's rows stay")
        let row = try #require(try SentHistory.rows(accountID: account, in: context).first { $0.uid == 3 })
        #expect(MessageIDList.decode(row.referenceIDs) == ["a0@friend.example"] && row.fromAddress == "me@work.example")
        #expect(try context.fetchCount(FetchDescriptor<ContactedAddress>()) == 1)
    }

    @Test func aRenumberedMailboxReplacesItsRows() async throws {
        let context = try seeded()
        #expect(await walk(SentMailbox(uidValidity: 6, headers: [header(1), header(2)]), in: context))
        #expect(try rows(context) == ["Sent|6|1", "Sent|6|2"])
    }

    @Test func anEmptySentFolderKeepsNothing() async throws {
        let context = try seeded()
        #expect(await walk(SentMailbox(uidValidity: 5, headers: []), in: context))
        #expect(try rows(context) == [])
    }

    @Test func stopDeletesNothing() async throws {
        for cancelAt in [SentMailbox.CancelAt.open, .lastBatch] {
            let context = try seeded()
            let before = try rows(context)
            #expect(await walk(SentMailbox(uidValidity: 6, headers: [header(1)], cancelAt: cancelAt), in: context) == false)
            try? context.save()
            #expect(Set(before).isSubset(of: Set(try rows(context))), "cancelled at \(cancelAt)")
        }
    }

    @Test func noUIDValidityLeavesTheHistoryAlone() async throws {
        let context = try seeded()
        let before = try rows(context)
        #expect(await walk(SentMailbox(uidValidity: nil, headers: [header(1, to: "bob@else.example"), header(9)]), in: context))
        #expect(try rows(context) == before)
        #expect(try context.fetchCount(FetchDescriptor<ContactedAddress>()) == 2, "contacts are still learned")
    }
}

struct ConversationBriefTests {
    private let account = UUID()

    private func message(_ uid: UInt32, from sender: String, _ subject: String, id: String?, references: [String]? = nil) -> MessageHeader {
        let m = MessageHeader(accountID: account, uid: uid, mailbox: "INBOX", subject: subject, senderName: "", senderAddress: sender,
                              receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(uid)), isUnread: true, isFlagged: false,
                              listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil, messageID: id.map { "<\($0)>" })
        if let references {
            m.referenceIDs = MessageIDList.encode(references)
            m.inReplyTo = MessageIDList.encode(Array(references.suffix(1)))
        }
        m.importance = .needsYou
        return m
    }

    @Test func aConversationWithSeveralSendersIsOneRow() {
        let mail = [
            message(1, from: "alice@friend.example", "Lunch Friday?", id: "a0@friend.example", references: []),
            message(2, from: "bob@else.example", "Re: Lunch Friday?", id: "b1@else.example", references: ["a0@friend.example"]),
            message(3, from: "carol@else.example", "Re: Lunch Friday?", id: "c2@else.example", references: ["a0@friend.example", "b1@else.example"]),
        ]
        let rows = BriefRanking.rank(mail, contactCounts: [:])
        #expect(rows.count == 1)
        #expect(Set(rows[0].thread.map(\.uid)) == [1, 2, 3], "Done acts on every message in the conversation")
    }

    @Test func theDigestListsAConversationOnce() {
        let mail = [
            message(1, from: "alice@friend.example", "Lunch Friday?", id: "a0@friend.example", references: []),
            message(2, from: "bob@else.example", "Re: Lunch Friday?", id: "b1@else.example", references: ["a0@friend.example"]),
            message(3, from: "billing@utility.example", "Your bill is ready", id: "m1@utility.example"),
        ]
        let scored = mail.map { m in (m, BriefRanking.rank([m], contactCounts: [:])[0].result) }
        #expect(scored.collapsedByThread().map(\.0.uid) == [1, 3])
    }

    @Test func sameSenderAndSubjectInDifferentConversationsAreTwoRows() {
        let mail = [
            message(1, from: "billing@utility.example", "Re: Invoice", id: "i1@billing.example", references: ["q1@me.example"]),
            message(2, from: "billing@utility.example", "Re: Invoice", id: "i2@billing.example", references: ["q2@me.example"]),
        ]
        #expect(BriefRanking.rank(mail, contactCounts: [:]).count == 2)
    }

    @Test func mailWithoutReplyIDsGroupsAsBefore() {
        let mail = [
            message(1, from: "billing@utility.example", "Your bill is ready", id: "m1@utility.example"),
            message(2, from: "billing@utility.example", "Your bill is ready", id: "m2@utility.example"),
            message(3, from: "orders@shop.example", "Your bill is ready", id: "m3@shop.example"),
        ]
        let rows = BriefRanking.rank(mail, contactCounts: [:])
        #expect(rows.count == 2)
        #expect(rows.map { $0.thread.count }.sorted() == [1, 2])
    }
}
