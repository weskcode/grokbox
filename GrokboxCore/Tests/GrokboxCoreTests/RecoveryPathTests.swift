import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

private actor Counter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

/// The recovery paths around a sweep: a server that renumbers, a reply that
/// never arrives, a connection that comes back, a message that is protected,
/// and an Undo that stops halfway. Each failure test breaks the demo server in
/// the one way a real one can and checks what Grokbox says happened against
/// what the server actually holds; the passing controls prove the fixture
/// would otherwise succeed.
@MainActor
@Suite(.serialized)
struct RecoveryPathTests {
    private struct IndexFailed: Error { var phase: String }

    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let account: MailAccount
        let mailbox: DemoMailbox
        let engine: SyncEngine
        let plan: CleanupPlan
        var context: ModelContext { container.mainContext }
        /// The mailbox the index walks: All Mail on Gmail, INBOX elsewhere.
        var indexed: String { mailbox.flavor.isGmail ? DemoMailbox.allMail : "INBOX" }
        var inbox: Set<UInt32> {
            if mailbox.flavor.isGmail {
                Set(mailbox.messages(in: DemoMailbox.allMail).filter { $0.labels.contains("\\Inbox") }.map(\.uid))
            } else {
                Set(mailbox.messages(in: "INBOX").map(\.uid))
            }
        }
    }

    nonisolated static let generic = DemoMailbox.Flavor.generic(delimiter: "/", inboxPrefix: false)

    private func fixture(flavor: DemoMailbox.Flavor, persona: DemoPersona = .neglected) async throws -> Fixture {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mailbox = DemoMailbox(persona: persona, flavor: flavor)
        let account = MailAccount(displayName: "Demo", username: mailbox.username, host: "127.0.0.1", port: 0, kind: .demo, security: .none)
        context.insert(account); try context.save()
        DemoRegistry.shared.register(mailbox, for: account.id)

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        guard case .finished = engine.phase else {
            DemoRegistry.shared.remove(account.id)
            throw IndexFailed(phase: engine.phase.label)
        }

        let suggested = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context), policy: .balanced)
        let items = suggested.enabledItems.prefix(4).map {
            CleanupPlan.Item(cluster: $0.cluster, archive: true, markRead: false, disposition: .fileIntoFolders)
        }
        return Fixture(container: container, account: account, mailbox: mailbox, engine: engine, plan: CleanupPlan(items: items))
    }

    private func actions(_ context: ModelContext) throws -> [CleanupAction] {
        try context.fetch(FetchDescriptor<CleanupAction>(sortBy: [SortDescriptor(\.performedAt)]))
    }

    private func headers(_ f: Fixture) throws -> [MessageHeader] {
        let id = f.account.id
        return try f.context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == id }))
    }

    // MARK: - UIDVALIDITY

    /// The audit's GB-112: neither guard was ever exercised with a stale
    /// snapshot. A sweep planned before the server renumbered must refuse to
    /// write, whatever the server flavour.
    @Test(arguments: [DemoMailbox.Flavor.gmail, RecoveryPathTests.generic])
    func aSweepPlannedBeforeARenumberWritesNothing(flavor: DemoMailbox.Flavor) async throws {
        let f = try await fixture(flavor: flavor)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let inboxBefore = f.inbox
        let writes = Counter()
        f.mailbox.beforeWrite = { _ in _ = await writes.next() }

        f.mailbox.uidValidity += 1
        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(f.plan, to: f.account, recordRules: true, guarded: false)

        guard case .failed(let why) = executor.phase else {
            Issue.record("a renumbered mailbox must stop the sweep, got \(executor.phase.label)"); return
        }
        #expect(why.localizedCaseInsensitiveContains("renumbered"))
        #expect(await writes.count == 0, "no message was moved, labelled or flagged")
        #expect(f.inbox == inboxBefore, "the server's inbox is untouched")
        #expect(try actions(f.context).isEmpty, "nothing is logged for work that never started")
        #expect(RuleStore.all(in: f.context).isEmpty, "no sender is approved by a refused sweep")
        #expect(try headers(f).allSatisfy { !$0.isSweptLocally })
    }

    /// On a plain server the executor creates its target folders before it
    /// reaches the UIDVALIDITY check, so a refused sweep still writes to the
    /// server. No mail moves, but the mailbox is not left as it was found.
    @Test func aSweepRefusedForARenumberCreatesNoFolders() async throws {
        let f = try await fixture(flavor: Self.generic)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let before = Set(f.mailbox.listMailboxes().map(\.name))
        f.mailbox.uidValidity += 1

        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(f.plan, to: f.account, recordRules: true, guarded: false)
        guard case .failed(let why) = executor.phase, why.localizedCaseInsensitiveContains("renumbered") else {
            Issue.record("the sweep must be refused for the renumber, got \(executor.phase.label)"); return
        }

        let created = Set(f.mailbox.listMailboxes().map(\.name)).subtracting(before)
        withKnownIssue("PlanExecutor.apply calls ensureMailbox before guardUIDValidity, so a refused sweep still creates folders") {
            #expect(created.isEmpty, "created \(created.sorted())")
        }
    }

    /// After a renumber the stored UIDs mean nothing. An incremental sync must
    /// throw them away and rebuild from what the server holds now.
    @Test func incrementalSyncAfterARenumberRebuildsFromTheServer() async throws {
        let f = try await fixture(flavor: Self.generic, persona: .personal)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let gone = Set(f.mailbox.messages(in: "INBOX").prefix(5).map(\.uid))
        f.mailbox.move(from: "INBOX", uids: gone, to: "Archive")
        f.mailbox.uidValidity += 1

        await f.engine.indexNow(account: f.account, mode: .incremental(fallbackLimit: 10_000))
        guard case .finished = f.engine.phase else { Issue.record("sync failed: \(f.engine.phase.label)"); return }

        let local = Set(try headers(f).map(\.uid))
        #expect(local == Set(f.mailbox.messages(in: "INBOX").map(\.uid)), "the index is exactly what the server holds")
        #expect(local.isDisjoint(with: gone))
        let snapshot = try #require(try f.context.fetch(FetchDescriptor<MailboxSnapshot>()).first)
        #expect(snapshot.uidValidity == f.mailbox.uidValidity)
    }

    // MARK: - Incremental sync

    /// GB-012, still open at bae8b57: the incremental pass fetches new UIDs and
    /// refreshes flags but has no delete path, so mail that left the mailbox
    /// through another client stays in the local index as if it were in the inbox.
    @Test func incrementalSyncDropsMailThatLeftTheMailbox() async throws {
        let f = try await fixture(flavor: Self.generic, persona: .personal)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let gone = Set(f.mailbox.messages(in: "INBOX").prefix(5).map(\.uid))
        f.mailbox.move(from: "INBOX", uids: gone, to: "Archive")

        await f.engine.indexNow(account: f.account, mode: .incremental(fallbackLimit: 10_000))
        guard case .finished = f.engine.phase else { Issue.record("sync failed: \(f.engine.phase.label)"); return }

        let stale = try headers(f).filter { gone.contains($0.uid) && $0.isInInbox }
        withKnownIssue("GB-012: incremental sync has no delete path, so vanished mail stays indexed as inbox mail") {
            #expect(stale.isEmpty, "\(stale.count) messages the server no longer has in the inbox are still indexed there")
        }
    }

    // MARK: - Lost acknowledgment

    /// The server applied a MOVE and the reply never came back. Grokbox cannot
    /// know that, so the record must say "may or may not", must not offer
    /// Undo (it does not know where the mail went), must not mark anything
    /// swept or approve the sender, and must end the run.
    @Test func aLostMoveAcknowledgmentIsRecordedAsUncertainAndEndsTheRun() async throws {
        let f = try await fixture(flavor: Self.generic)
        defer { DemoRegistry.shared.remove(f.account.id) }
        try #require(f.plan.items.count >= 2)
        var plan = f.plan
        plan.items[0].unsubscribe = true
        let victim = plan.items[0].cluster.address
        let victimUIDs = Set(plan.items[0].cluster.pendingUIDs)
        let moves = Counter()
        f.mailbox.beforeWrite = { [mailbox = f.mailbox] write in
            guard write.operation == "MOVE", await moves.next() == 1 else { return }
            mailbox.move(from: "INBOX", uids: Set(write.uids), to: write.values[0])
            throw IMAPError.connectionClosed
        }

        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(plan, to: f.account, recordRules: true, guarded: false)

        guard case .failed = executor.phase else { Issue.record("expected failure, got \(executor.phase.label)"); return }
        #expect(await moves.count == 1, "no second sender was attempted on a dead connection")
        #expect(f.inbox.isDisjoint(with: victimUIDs), "the server really did move the mail")

        let logged = try actions(f.context)
        #expect(Set(logged.map(\.senderAddress)) == [victim])
        #expect(logged.map(\.kind) == [.archive], "no unsubscribe after an archive that may have failed")
        let move = try #require(logged.first)
        #expect(move.errorMessage?.contains("may or may not have happened") == true)
        #expect(!move.isUndoable, "without COPYUID Grokbox cannot find the mail to bring back")
        #expect(RuleStore.all(in: f.context).isEmpty)
        #expect(try headers(f).allSatisfy { !$0.isSweptLocally }, "nothing is marked swept on an unconfirmed move")
    }

    /// After that lost acknowledgment the next sync is how Grokbox learns the
    /// truth. Until it does, a retry would send MOVE for UIDs that are no
    /// longer in the inbox. Same root cause as GB-012.
    @Test func afterALostMoveAcknowledgmentTheNextSyncStopsOfferingThatMail() async throws {
        let f = try await fixture(flavor: Self.generic)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let victim = f.plan.items[0].cluster.address
        let moved = Set(f.plan.items[0].cluster.pendingUIDs)
        let moves = Counter()
        f.mailbox.beforeWrite = { [mailbox = f.mailbox] write in
            guard write.operation == "MOVE", await moves.next() == 1 else { return }
            mailbox.move(from: "INBOX", uids: Set(write.uids), to: write.values[0])
            throw IMAPError.connectionClosed
        }
        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(f.plan, to: f.account, recordRules: true, guarded: false)
        f.mailbox.beforeWrite = nil
        #expect(await moves.count == 1, "the lost-acknowledgment scenario ran")
        #expect(f.inbox.isDisjoint(with: moved), "the server really did move the mail")
        #expect(try actions(f.context).first?.errorMessage?.contains("may or may not have happened") == true)

        await f.engine.indexNow(account: f.account, mode: .incremental(fallbackLimit: 10_000))
        guard case .finished = f.engine.phase else { Issue.record("sync failed: \(f.engine.phase.label)"); return }
        let pending = Set(SenderProfileBuilder.assessments(for: f.account, in: f.context)
            .first { $0.cluster.address == victim }?.cluster.pendingUIDs ?? [])
        withKnownIssue("GB-012: the stale rows keep the moved mail pending, so a replay targets UIDs the server no longer has") {
            #expect(pending.isDisjoint(with: moved), "\(pending.intersection(moved).count) moved messages are still offered for sweeping")
        }
    }

    // MARK: - Reconnect

    /// A dropped connection must not poison the next run on the same executor:
    /// the earlier uncertain record stays as evidence, the retry completes, and
    /// the server ends up holding exactly what the plan asked for.
    @Test func aDroppedConnectionDoesNotPoisonTheNextRun() async throws {
        let f = try await fixture(flavor: .gmail)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let writes = Counter()
        f.mailbox.beforeWrite = { _ in
            if await writes.next() == 1 { throw IMAPError.connectionClosed }
        }
        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(f.plan, to: f.account, recordRules: true, guarded: false)
        guard case .failed = executor.phase else { Issue.record("expected failure, got \(executor.phase.label)"); return }
        let uncertain = try #require(try actions(f.context).first)
        #expect(uncertain.errorMessage?.contains("may or may not have happened") == true)
        #expect(RuleStore.all(in: f.context).isEmpty)

        f.mailbox.beforeWrite = nil
        await executor.apply(f.plan, to: f.account, recordRules: true, guarded: false)
        guard case .finished = executor.phase else { Issue.record("the retry did not finish: \(executor.phase.label)"); return }
        #expect(executor.lastOutcome.failedSenders == 0)
        #expect(executor.lastOutcome.senders == f.plan.items.count)
        #expect(Set(RuleStore.all(in: f.context).keys) == Set(f.plan.items.map(\.cluster.address)))
        #expect(uncertain.errorMessage?.contains("may or may not have happened") == true, "the earlier record is kept, not rewritten")
        let planned = Set(f.plan.items.flatMap(\.cluster.pendingUIDs))
        #expect(f.inbox.isDisjoint(with: planned), "every planned message left the inbox")
        for item in f.plan.items {
            let labelled = Set(f.mailbox.messages(in: DemoMailbox.allMail).filter { $0.labels.contains(item.folder) }.map(\.uid))
            #expect(Set(item.cluster.pendingUIDs).isSubset(of: labelled), "\(item.cluster.address) is filed under \(item.folder)")
        }
    }

    /// A label change whose acknowledgment was lost may have landed. Undo is
    /// offered because putting the label back is safe either way, and it does
    /// restore what the server holds.
    @Test func aLabelWhoseAcknowledgmentWasLostCanStillBeUndone() async throws {
        let f = try await fixture(flavor: .gmail)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let item = f.plan.items[0]
        let uids = Set(item.cluster.pendingUIDs)
        let writes = Counter()
        f.mailbox.beforeWrite = { [mailbox = f.mailbox] write in
            guard write.operation == "+X-GM-LABELS", await writes.next() == 1 else { return }
            mailbox.store(in: DemoMailbox.allMail, uids: Set(write.uids), add: true, labels: write.values)
            throw IMAPError.connectionClosed
        }
        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(CleanupPlan(items: [item]), to: f.account, recordRules: false, guarded: false)
        f.mailbox.beforeWrite = nil

        let uncertain = try #require(try actions(f.context).first { $0.kind == .label })
        #expect(uncertain.errorMessage?.contains("may or may not have happened") == true)
        #expect(uncertain.isUndoable)
        let carries = { f.mailbox.messages(in: DemoMailbox.allMail).filter { uids.contains($0.uid) && $0.labels.contains(item.folder) }.count }
        #expect(carries() == uids.count, "the label really did land")

        await executor.undo(uncertain, on: f.account)
        #expect(uncertain.isUndone, "undo: \(executor.phase.label)")
        #expect(carries() == 0, "the label is gone from the server")
        #expect(uids.isSubset(of: f.inbox), "the mail never left the inbox")
    }

    // MARK: - Protected messages

    /// A flagged message inside a swept sender stays in the inbox on the
    /// server and is named in the log, whatever the policy.
    @Test(arguments: [DemoMailbox.Flavor.gmail, RecoveryPathTests.generic])
    func aFlaggedMessageInsideASweptSenderStaysInTheInbox(flavor: DemoMailbox.Flavor) async throws {
        let f = try await fixture(flavor: flavor)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let victim = try #require(f.plan.items.first { $0.cluster.pendingUIDs.count >= 3 })
        let protected = try #require(victim.cluster.pendingUIDs.max())
        let subject = try #require(try headers(f).first { $0.uid == protected }?.subject)
        try #require(!SweepGuard.looksTransactional(subject), "only the flag may protect this message")
        f.mailbox.store(in: f.indexed, uids: [protected], add: true, flags: ["\\Flagged"])
        await f.engine.indexNow(account: f.account, mode: .full(limit: 10_000))
        #expect(try headers(f).first { $0.uid == protected }?.isFlagged == true, "the re-index picked up the flag")

        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(f.plan, to: f.account, recordRules: true, guarded: true, policy: .thorough)
        guard case .finished = executor.phase else { Issue.record("sweep: \(executor.phase.label)"); return }

        #expect(f.inbox.contains(protected), "the flagged message never left the inbox")
        #expect(f.inbox.isDisjoint(with: Set(victim.cluster.pendingUIDs).subtracting([protected])), "the rest of that sender was swept")
        let held = try actions(f.context).filter { $0.senderAddress == victim.cluster.address }.flatMap(\.heldUIDs)
        #expect(held.contains(protected), "the log names what was held")
        let summary = try actions(f.context).filter { $0.senderAddress == victim.cluster.address }.compactMap(\.heldSummary)
        #expect(summary.contains { $0.contains("flagged") }, "and says why: \(summary)")
    }

    /// The guard reads flags from the local index, so a message flagged on
    /// another device since the last index is not protected. Undo recovers it,
    /// but the promise "flagged mail is never swept" does not hold until the
    /// executor checks live flags or the plan is refreshed first.
    @Test(arguments: [DemoMailbox.Flavor.gmail, RecoveryPathTests.generic])
    func aMessageFlaggedSinceTheLastIndexIsStillProtected(flavor: DemoMailbox.Flavor) async throws {
        let f = try await fixture(flavor: flavor)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let victim = try #require(f.plan.items.first { $0.cluster.pendingUIDs.count >= 3 })
        let protected = try #require(victim.cluster.pendingUIDs.max())
        let subject = try #require(try headers(f).first { $0.uid == protected }?.subject)
        try #require(!SweepGuard.looksTransactional(subject), "only the flag may protect this message")
        f.mailbox.store(in: f.indexed, uids: [protected], add: true, flags: ["\\Flagged"])
        #expect(f.mailbox.messages(in: f.indexed).first { $0.uid == protected }?.flags.contains("\\Flagged") == true, "flagged on the server")
        #expect(try headers(f).first { $0.uid == protected }?.isFlagged == false, "but not in the local index")

        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(f.plan, to: f.account, recordRules: true, guarded: true, policy: .thorough)
        guard case .finished = executor.phase else { Issue.record("sweep: \(executor.phase.label)"); return }

        withKnownIssue("the guard uses flags as of the last index, so a message flagged since then is swept") {
            #expect(f.inbox.contains(protected), "a message flagged on another device was archived")
        }
    }

    // MARK: - Undo

    /// An Undo that fails partway reports failure and keeps the action open.
    /// Running it again finishes the job, because putting a label back is safe
    /// to repeat. The demo provider does not chunk, so the failure is injected
    /// as the error the real client raises after chunk one: a later chunk is
    /// refused (the first chunk is confirmed, the rest did nothing), or the
    /// connection is lost (the first chunk is confirmed, the rest may have
    /// landed). The 500-UID chunking itself is covered by `IMAPClientTests`.
    @Test(arguments: [false, true])
    func anUndoThatStopsHalfwayCanBeRunAgain(lostConnection: Bool) async throws {
        let f = try await fixture(flavor: .gmail)
        defer { DemoRegistry.shared.remove(f.account.id) }
        let executor = PlanExecutor(modelContext: f.context)
        await executor.apply(f.plan, to: f.account, recordRules: false, guarded: false)
        guard case .finished = executor.phase else { Issue.record("sweep: \(executor.phase.label)"); return }
        let archive = try #require(try actions(f.context).first { $0.kind == .archive && $0.isUndoable && $0.uids.count >= 2 })
        let uids = archive.uids.sorted()
        let applied = Array(uids.prefix(uids.count / 2))
        let rest = Array(uids.dropFirst(applied.count))
        #expect(f.inbox.isDisjoint(with: Set(uids)))

        f.mailbox.beforeWrite = { [mailbox = f.mailbox] write in
            guard write.operation == "+X-GM-LABELS", write.values == ["\\Inbox"] else { return }
            mailbox.store(in: DemoMailbox.allMail, uids: Set(lostConnection ? uids : applied), add: true, labels: ["\\Inbox"])
            throw PartialWriteError(applied: applied, unsure: lostConnection ? rest : [], reason: lostConnection ? "connection lost" : "NO test refusal")
        }
        await executor.undo(archive, on: f.account)

        guard case .failed = executor.phase else { Issue.record("expected failure, got \(executor.phase.label)"); return }
        #expect(!archive.isUndone, "a half-finished undo is not recorded as done")
        #expect(f.inbox.intersection(Set(uids)) == Set(lostConnection ? uids : applied))

        f.mailbox.beforeWrite = nil
        await executor.undo(archive, on: f.account)
        #expect(archive.isUndone, "undo: \(executor.phase.label)")
        #expect(Set(uids).isSubset(of: f.inbox), "every message is back")
    }
}
