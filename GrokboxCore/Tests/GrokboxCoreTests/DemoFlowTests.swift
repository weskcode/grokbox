import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

/// The whole app, minus the pixels: every engine the UI calls, in the order a
/// user would, against a live demo server. If this passes, the buttons work.
@MainActor
@Suite(.serialized)
struct DemoFlowTests {
    /// These tests exercise the sweep *mechanics*, so they fix the policy
    /// rather than inheriting whatever the user's default happens to be:
    /// file everything into folders, mark it read, unsubscribe from nothing.
    private var sweepEverything: CleanupPolicy {
        var policy = CleanupPolicy.thorough
        policy.promotionDisposition = nil
        policy.unsubscribe = .never
        policy.markRead = true
        return policy
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self, SenderRule.self, MailboxSnapshot.self, SenderProfile.self, InboxDigest.self])
        return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func makeAccount(for server: DemoMailServer, in context: ModelContext) throws -> MailAccount {
        let account = MailAccount(displayName: "Demo", username: server.username, host: "127.0.0.1",
                                  port: Int(server.port), kind: .demo, security: .none)
        context.insert(account)
        try context.save()
        try KeychainStore.save(password: DemoMailServer.password, for: account.keychainAccount)
        return account
    }

    /// What the app's screens use: the persisted, categorised profiles.
    private func assessments(for account: MailAccount, in context: ModelContext) throws -> [SenderAssessment] {
        SenderProfileBuilder.assessments(for: account, in: context)
    }

    @Test func indexSweepUndoAndIncrementalSync() async throws {
        let server = try DemoMailServer(persona: .personal)
        try await server.start()
        defer { server.stop() }

        let container = try makeContainer()
        let context = container.mainContext
        let account = try makeAccount(for: server, in: context)
        defer { try? KeychainStore.delete(account: account.keychainAccount) }

        // 1. Index (what the Senders → Index button does)
        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        guard case .finished = engine.phase else { Issue.record("index failed: \(engine.phase.label)"); return }

        let serverCount = server.messages(in: "[Gmail]/All Mail").count
        let id = account.id
        let indexed = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id }))
        #expect(indexed.count == serverCount, "every message indexed")
        #expect(indexed.contains { !$0.isInInbox }, "already-archived mail is marked as such")

        let contacts = Set(try context.fetch(FetchDescriptor<ContactedAddress>()).map(\.address))
        #expect(contacts.contains("alice@adamsfamily.example"), "learned from Sent")

        let snapshot = try #require(try context.fetch(FetchDescriptor<MailboxSnapshot>()).first)
        #expect(snapshot.uidValidity == DemoMailServer.uidValidity)
        #expect(snapshot.highestUID == indexed.map(\.uid).max())

        // 2. Assess (the Senders table)
        var assessed = try assessments(for: account, in: context)
        let alice = try #require(assessed.first { $0.cluster.address == "alice@adamsfamily.example" })
        let megamart = try #require(assessed.first { $0.cluster.address == "offers@megamart.example" })
        #expect(alice.verdict == .keep)
        #expect(megamart.verdict == .bulk)
        #expect(megamart.cluster.supportsOneClickUnsubscribe)

        // 3. Plan and apply (the Sweep screen)
        let plan = CleanupPlan.suggested(from: assessed, rules: RuleStore.all(in: context), policy: sweepEverything)
        #expect(!plan.isEmpty)
        #expect(plan.items.allSatisfy { $0.cluster.address != "alice@adamsfamily.example" }, "never proposes a contact")
        #expect(plan.items.first { $0.cluster.address == "offers@megamart.example" }?.folder == "Grokbox/Promotions")
        #expect(plan.items.first { $0.cluster.address == "notifications@linkedin.example" }?.folder == "Grokbox/Notifications")
        #expect(plan.items.allSatisfy { $0.cluster.category != .transactional }, "receipt senders are never in a suggested sweep")
        let inboxBefore = server.messages(in: "INBOX").count
        let planned = plan.enabledMessageCount

        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, policy: sweepEverything)
        guard case .finished = executor.phase else { Issue.record("apply failed: \(executor.phase.label)"); return }

        let actionsSoFar = try context.fetch(FetchDescriptor<CleanupAction>())
        let held = actionsSoFar.filter { $0.kind == .archive }.reduce(0) { $0 + $1.heldUIDs.count }
        #expect(server.messages(in: "INBOX").count == inboxBefore - planned + held, "inbox shrank by the plan minus what the guard held")
        #expect(held > 0, "the guard held at least one receipt-looking message inside a bulk sender")
        let swept = try #require(server.messages(in: "[Gmail]/All Mail").first { $0.fromAddress == "offers@megamart.example" && $0.labels.contains("Grokbox/Promotions") })
        #expect(!swept.labels.contains("\\Inbox"))
        #expect(swept.flags.contains("\\Seen"))

        let actions = try context.fetch(FetchDescriptor<CleanupAction>())
        #expect(actions.contains { $0.kind == .archive && $0.errorMessage == nil && $0.isUndoable })
        #expect(RuleStore.all(in: context)["offers@megamart.example"] == .sweep, "approval wrote a rule")

        assessed = try assessments(for: account, in: context)
        #expect(try #require(assessed.first { $0.cluster.address == "offers@megamart.example" }).cluster.pendingUIDs.isEmpty, "nothing left to sweep locally")

        // 4. Undo one archive (the Activity screen)
        let undoTarget = try #require(actions.first { $0.kind == .archive && $0.senderAddress == "offers@megamart.example" })
        await executor.undo(undoTarget, on: account)
        guard case .finished = executor.phase else { Issue.record("undo failed: \(executor.phase.label)"); return }
        #expect(undoTarget.isUndone)
        let restored = server.messages(in: "[Gmail]/All Mail").filter { undoTarget.uids.contains($0.uid) }
        #expect(restored.allSatisfy { $0.labels.contains("\\Inbox") }, "undo put them back in the inbox")

        // 5. Incremental sync sees the server's truth (tidy-up path)
        await engine.indexNow(account: account, mode: .incremental(fallbackLimit: 100))
        guard case .finished(let message) = engine.phase else { Issue.record("incremental failed: \(engine.phase.label)"); return }
        #expect(message == "Nothing new")
        let afterSync = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id }))
        let backInInbox = afterSync.filter { undoTarget.uids.contains($0.uid) }
        #expect(backInInbox.allSatisfy { $0.isInInbox && !$0.isSweptLocally })

        // 6. Maintenance applies the rule again — and only the rule
        let maintainer = Maintainer(modelContext: context, engine: engine, executor: executor)
        RuleStore.set(.keep, for: "hello@morningdigest.example", in: context)
        let digestInboxBefore = server.messages(in: "INBOX").filter { $0.fromAddress == "hello@morningdigest.example" }.count
        await maintainer.run(accounts: [account], model: nil, settings: .init(isAutoEnabled: false, intervalMinutes: 30, readLimit: 10, indexDepth: 100), policy: sweepEverything)
        guard case .finished = maintainer.phase else { Issue.record("maintain failed: \(maintainer.phase.label)"); return }
        #expect(server.messages(in: "INBOX").filter { $0.fromAddress == "offers@megamart.example" }.isEmpty, "sweep rule re-applied")
        #expect(server.messages(in: "INBOX").filter { $0.fromAddress == "hello@morningdigest.example" }.count == digestInboxBefore, "keep rule respected")
    }

    @Test func firstTidyUpLearnsContactsAndPlacesPeople() async throws {
        let server = try DemoMailServer(persona: .personal)
        try await server.start()
        defer { server.stop() }
        let container = try makeContainer()
        let context = container.mainContext
        let account = try makeAccount(for: server, in: context)
        defer { try? KeychainStore.delete(account: account.keychainAccount) }

        // What Maintainer does on a brand-new account: incremental with a fallback.
        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .incremental(fallbackLimit: 5_000))
        guard case .finished = engine.phase else { Issue.record("index failed: \(engine.phase.label)"); return }

        let contacts = Set(try context.fetch(FetchDescriptor<ContactedAddress>()).map(\.address))
        #expect(contacts.contains("ben.okafor@workmail.example"), "Sent mailbox scanned on the first pass")

        let ben = try #require(SenderProfileBuilder.profiles(for: account, in: context).first { $0.address == "ben.okafor@workmail.example" })
        #expect(ben.category == .person)
        #expect(ben.categoryEvidence == "You have written to this address")
        #expect(ben.recommendation == .keep)

        let bank = try #require(SenderProfileBuilder.profiles(for: account, in: context).first { $0.address == "alerts@northbank.example" })
        #expect(bank.category == .transactional, "bank alerts are records, not notifications")
    }

    @Test func readPassWithStubModel() async throws {
        let server = try DemoMailServer(persona: .work)
        try await server.start()
        defer { server.stop() }

        let container = try makeContainer()
        let context = container.mainContext
        let account = try makeAccount(for: server, in: context)
        defer { try? KeychainStore.delete(account: account.keychainAccount) }

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))

        let stub = StubModel()
        await engine.readNow(account: account, model: stub, limit: 25)
        guard case .finished = engine.phase else { Issue.record("read failed: \(engine.phase.label)"); return }

        let id = account.id
        let read = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id && $0.readAt != nil }))
        #expect(read.contains { $0.summary != nil }, "model output stored")
        #expect(read.contains { $0.importance == .noise && $0.summary == nil }, "bulk senders skipped the model but still got classified")
        let requests = await stub.requests
        #expect(requests.count <= 25, "read budget respected")
        #expect(requests.allSatisfy { !$0.bodyExcerpt.contains("<html") }, "bodies reach the model as text")
        #expect(requests.contains { $0.senderIsKnownContact }, "contact signal reaches the model")
        #expect(read.contains { $0.actionType == .reply && $0.isQuick }, "action and quick signals stored")
        #expect(read.contains { $0.dueAt != nil }, "due hint parsed into a date")

        let profiles = SenderProfileBuilder.profiles(for: account, in: context)
        #expect(profiles.allSatisfy { $0.category != .unknown || !$0.categoryConfident })
        #expect(profiles.contains { $0.categoryFromModel }, "model placed at least one unsorted sender")
        #expect(profiles.contains { $0.recommendation == .unsubscribeAndSweep })
        #expect(profiles.contains { $0.recommendation == .keep && $0.category == .person })
    }

    /// The real thing, when this Mac can run it. Skipped silently otherwise.
    @Test func readPassWithAppleOnDeviceModel() async throws {
        guard #available(macOS 26.0, *) else { return }
        let apple = FoundationModelsProvider()
        guard await apple.availability().isAvailable else { return }

        let server = try DemoMailServer(persona: .personal)
        try await server.start()
        defer { server.stop() }

        let container = try makeContainer()
        let context = container.mainContext
        let account = try makeAccount(for: server, in: context)
        defer { try? KeychainStore.delete(account: account.keychainAccount) }

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        await engine.readNow(account: account, model: apple, limit: 6)
        guard case .finished = engine.phase else { Issue.record("read failed: \(engine.phase.label)"); return }

        let id = account.id
        let read = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id && $0.summary != nil }))
        #expect(read.count >= 3, "model produced summaries")
        for message in read {
            #expect(message.summary!.count > 10 && message.summary!.count < 300)
            #expect(message.importance != nil)
        }
    }
}

/// Deterministic stand-in for a language model.
actor StubModel: TextModel {
    nonisolated let name = "Stub"
    private(set) var requests: [ReadRequest] = []

    func availability() async -> ModelAvailability { .available }

    func read(_ request: ReadRequest) async throws -> ReadResult {
        requests.append(request)
        let needs = request.senderIsKnownContact || request.bodyExcerpt.localizedCaseInsensitiveContains("due")
        return ReadResult(summary: "Stub: \(request.subject.prefix(40))", importance: needs ? .needsYou : .worthKnowing, reason: "stub",
                          actionType: needs ? .reply : .none, dueHint: needs ? "tomorrow" : nil, isQuick: needs)
    }

    private(set) var categorized: [CategorizeRequest] = []

    func categorize(_ request: CategorizeRequest) async throws -> CategorizeResult {
        categorized.append(request)
        return CategorizeResult(category: request.hasUnsubscribeLink ? .newsletter : .person, reason: "stub")
    }
}

@MainActor
struct DigestTests {
    @Test func digestReflectsTheInboxAndKeepsHistory() async throws {
        let server = try DemoMailServer(persona: .personal)
        try await server.start()
        defer { server.stop() }
        let schema = Schema([MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self, SenderRule.self, MailboxSnapshot.self, SenderProfile.self, InboxDigest.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = MailAccount(displayName: "Demo", username: server.username, host: "127.0.0.1", port: Int(server.port), kind: .demo, security: .none)
        context.insert(account); try context.save()
        try KeychainStore.save(password: DemoMailServer.password, for: account.keychainAccount)
        defer { try? KeychainStore.delete(account: account.keychainAccount) }

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        await engine.readNow(account: account, model: StubModel(), limit: 20)

        let first = try DigestBuilder.build(for: [account], in: context)
        #expect(first.needsYou > 0)
        #expect(first.topItems.count == min(5, first.needsYou))
        #expect(first.topItems.first!.score >= first.topItems.last!.score, "ordered by priority")
        let keys = first.topItems.map { $0.sender + "|" + $0.subject.lowercased() }
        #expect(Set(keys).count == keys.count, "no repeated sender+subject in the top items")
        #expect(first.pendingBulkSenders > 0, "nothing swept yet, so bulk is pending")
        #expect(first.unsubscribeCandidates > 0)
        #expect(first.headline.contains("need"))
        #expect(first.narrative.contains("waiting for your decision in Sweep"))
        #expect(first.asText.contains("Start with:"))

        let executor = PlanExecutor(modelContext: context)
        var sweepAll = CleanupPolicy.thorough
        sweepAll.promotionDisposition = nil
        sweepAll.unsubscribe = .never
        await executor.apply(CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context), policy: sweepAll),
                             to: account, policy: sweepAll)
        let second = try DigestBuilder.build(for: [account], in: context)
        #expect(second.sweptToday > 0)
        #expect(second.pendingBulkSenders < first.pendingBulkSenders)
        #expect(second.narrative.contains("filed today"))

        let history = try context.fetch(FetchDescriptor<InboxDigest>())
        #expect(history.count == 2, "snapshots are kept")
        #expect(DigestBuilder.latest(scopeKey: account.id.uuidString, in: context)?.id == second.id)
    }
}

@MainActor
struct CatchUpTests {
    @Test func catchUpReadsOnlyPeopleAndRecords() async throws {
        let server = try DemoMailServer(persona: .neglected)
        try await server.start()
        defer { server.stop() }
        let schema = Schema([MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self, SenderRule.self, MailboxSnapshot.self, SenderProfile.self, InboxDigest.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = MailAccount(displayName: "Old", username: server.username, host: "127.0.0.1", port: Int(server.port), kind: .demo, security: .none)
        context.insert(account); try context.save()
        try KeychainStore.save(password: DemoMailServer.password, for: account.keychainAccount)
        defer { try? KeychainStore.delete(account: account.keychainAccount) }

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))

        let stub = StubModel()
        await engine.readNow(account: account, model: stub, limit: 40, scope: .catchUp(days: 365))
        guard case .finished = engine.phase else { Issue.record("catch-up failed: \(engine.phase.label)"); return }

        let requests = await stub.requests
        #expect(!requests.isEmpty)
        let profiles = Dictionary(SenderProfileBuilder.profiles(for: account, in: context).map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        for request in requests {
            let category = profiles[request.senderAddress]?.category
            #expect(category == .person || category == .transactional, "\(request.senderAddress) is \(String(describing: category))")
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        #expect(requests.contains { $0.receivedAt < cutoff }, "reached past the normal 30-day window")
    }
}

@MainActor
struct SnoozeTests {
    @Test func snoozedMailLeavesTheBriefAndTheDigestUntilItsTime() throws {
        let schema = Schema([MailAccount.self, MessageHeader.self, ContactedAddress.self, CleanupAction.self, SenderRule.self, MailboxSnapshot.self, SenderProfile.self, InboxDigest.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let account = MailAccount(displayName: "A", username: "a@x", host: "h", port: 1, kind: .generic, security: .tls)
        context.insert(account)
        account.lastSyncedAt = .now

        func message(_ uid: UInt32, subject: String) -> MessageHeader {
            let m = MessageHeader(accountID: account.id, uid: uid, mailbox: "INBOX", subject: subject, senderName: "Alice", senderAddress: "alice@x",
                                  receivedAt: .now, isUnread: true, isFlagged: false, listUnsubscribe: nil, listUnsubscribePost: nil, listID: nil, messageID: nil)
            m.importance = .needsYou
            m.summary = "Alice asks."
            m.readAt = .now
            context.insert(m)
            return m
        }
        let a = message(1, subject: "Lunch?")
        let b = message(2, subject: "Dinner?")
        try context.save()

        let before = try DigestBuilder.build(for: [account], in: context)
        #expect(before.needsYou == 2)

        b.snoozedUntil = Date().addingTimeInterval(3600)
        #expect(b.isSnoozed)
        let during = try DigestBuilder.build(for: [account], in: context)
        #expect(during.needsYou == 1)
        #expect(during.topItems.map(\.subject) == ["Lunch?"])

        b.snoozedUntil = Date().addingTimeInterval(-60)
        #expect(!b.isSnoozed, "past its time, it is back")
        let after = try DigestBuilder.build(for: [account], in: context)
        #expect(after.needsYou == 2)
        _ = a
    }
}
