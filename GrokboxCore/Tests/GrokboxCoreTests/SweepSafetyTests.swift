import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

/// Counts writes as the demo provider sees them.
private actor WriteCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

/// What the sweep does when it is stopped, refused, or cut short. Every one of
/// these used to be reported as a clean success, or to leave sweep rules behind
/// for senders that were never dealt with.
@MainActor
@Suite(.serialized)
struct SweepSafetyTests {
    private func setUp(persona: DemoPersona = .neglected, flavor: DemoMailbox.Flavor = .gmail) async throws
        -> (ModelContainer, MailAccount, DemoMailbox, CleanupPlan) {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mailbox = DemoMailbox(persona: persona, flavor: flavor)
        let account = MailAccount(displayName: "Demo", username: mailbox.username, host: "127.0.0.1", port: 0, kind: .demo, security: .none)
        context.insert(account); try context.save()
        DemoRegistry.shared.register(mailbox, for: account.id)

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        guard case .finished = engine.phase else { throw IndexFailed(phase: engine.phase.label) }

        // Fixed flags so the test does not depend on the runner's saved policy:
        // file into folders, no mark-read, no unsubscribe.
        let suggested = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context))
        let items = suggested.enabledItems.prefix(4).map {
            CleanupPlan.Item(cluster: $0.cluster, archive: true, markRead: false, disposition: .fileIntoFolders)
        }
        return (container, account, mailbox, CleanupPlan(items: items))
    }

    private struct IndexFailed: Error { var phase: String }

    @Test func stopPartwayWritesNothingMoreAndLeavesNoRules() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        let context = container.mainContext
        try #require(plan.items.count >= 3)

        let executor = PlanExecutor(modelContext: context)
        let writes = WriteCounter()
        mailbox.beforeWrite = { _ in
            if await writes.next() == 1 { await MainActor.run { executor.cancel() } }
        }
        await executor.apply(plan, to: account, recordRules: true, guarded: false)

        guard case .finished(let message) = executor.phase else {
            Issue.record("expected a stopped finish, got \(executor.phase.label)"); return
        }
        #expect(message.hasPrefix("Stopped"))
        #expect(executor.lastOutcome.stopped)
        #expect(await writes.count == 1, "nothing is written after Stop")
        // No sender got as far as having its mail filed, so none has a rule
        // for the next tidy-up to act on.
        #expect(RuleStore.all(in: context).isEmpty)
        let touchedSenders = Set(try context.fetch(FetchDescriptor<CleanupAction>()).map(\.senderAddress))
        #expect(touchedSenders == [plan.items[0].cluster.address])
    }

    @Test func aRefusedLabelKeepsThatSendersMailInTheInboxAndSkipsItsUnsubscribe() async throws {
        let (container, account, mailbox, basePlan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        let context = container.mainContext
        try #require(basePlan.items.count >= 2)

        var plan = basePlan
        plan.items[0].unsubscribe = true
        let victim = plan.items[0].cluster.address
        let victimUIDs = Set(plan.items[0].cluster.pendingUIDs)
        mailbox.beforeWrite = { write in
            if write.operation == "+X-GM-LABELS", Set(write.uids).isSubset(of: victimUIDs) {
                throw IMAPError.commandFailed(command: "UID STORE", response: "NO test refusal")
            }
        }

        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, recordRules: true, guarded: false)

        guard case .failed(let why) = executor.phase else {
            Issue.record("a failed sender must not read as success: \(executor.phase.label)"); return
        }
        #expect(why.contains("1 sender failed"))
        #expect(executor.lastOutcome.failedSenders == 1)
        #expect(executor.lastOutcome.senders == plan.items.count - 1)

        // The victim's mail never left the inbox, locally or on the server.
        let inbox = Set(mailbox.messages(in: "INBOX").map(\.uid))
        #expect(victimUIDs.isSubset(of: inbox))
        let accountID = account.id
        let swept = try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == accountID && $0.isSweptLocally }))
        #expect(swept.allSatisfy { !victimUIDs.contains($0.uid) })

        let actions = try context.fetch(FetchDescriptor<CleanupAction>())
        let victimActions = actions.filter { $0.senderAddress == victim }
        #expect(victimActions.map(\.kind) == [.label], "no archive and no unsubscribe after a failed label")
        #expect(victimActions.first?.errorMessage?.contains("test refusal") == true)
        #expect(victimActions.first?.isUndoable == false)

        // Everyone else went through, is undoable, and has a rule.
        let rules = RuleStore.all(in: context)
        #expect(rules[victim] == nil)
        for item in plan.items.dropFirst() {
            #expect(rules[item.cluster.address] == .sweep)
            let archives = actions.filter { $0.senderAddress == item.cluster.address && $0.kind == .archive }
            #expect(archives.count == 1)
            #expect(archives.allSatisfy { $0.errorMessage == nil && $0.isUndoable })
        }
    }

    /// The record is saved before the command goes out. Until the server
    /// confirms, it must say so rather than look like a finished action. A
    /// label change stays undoable meanwhile, because putting it back is safe
    /// whether or not it landed; a move does not (see the next test).
    @Test func aLabelInFlightIsRecordedAsInterruptedButUndoable() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        let seen = WriteCounter()
        final class Snapshot: @unchecked Sendable { var error: String?; var undoable = true }
        let snapshot = Snapshot()
        mailbox.beforeWrite = { _ in
            guard await seen.next() == 1 else { return }
            await MainActor.run {
                let action = try? container.mainContext.fetch(FetchDescriptor<CleanupAction>()).first
                snapshot.error = action?.errorMessage
                snapshot.undoable = action?.isUndoable ?? true
            }
        }

        let executor = PlanExecutor(modelContext: container.mainContext)
        await executor.apply(plan, to: account, recordRules: false, guarded: false)

        #expect(snapshot.error == PlanExecutor.interrupted)
        #expect(snapshot.undoable == true)
        let settled = try container.mainContext.fetch(FetchDescriptor<CleanupAction>())
        #expect(settled.allSatisfy { $0.errorMessage == nil && $0.isUndoable }, "confirmation clears the interruption")
    }

    @Test func aMoveInFlightIsNotUndoableUntilTheServerSaysWhereItWent() async throws {
        let (container, account, mailbox, plan) = try await setUp(flavor: .generic(delimiter: "/", inboxPrefix: false))
        defer { DemoRegistry.shared.remove(account.id) }
        final class Snapshot: @unchecked Sendable { var error: String?; var undoable = true }
        let snapshot = Snapshot()
        let seen = WriteCounter()
        mailbox.beforeWrite = { write in
            guard write.operation == "MOVE", await seen.next() == 1 else { return }
            await MainActor.run {
                let action = try? container.mainContext.fetch(FetchDescriptor<CleanupAction>()).first { $0.targetMailbox != nil }
                snapshot.error = action?.errorMessage
                snapshot.undoable = action?.isUndoable ?? true
            }
        }
        await PlanExecutor(modelContext: container.mainContext).apply(plan, to: account, recordRules: false, guarded: false)

        #expect(snapshot.error == PlanExecutor.interrupted)
        #expect(snapshot.undoable == false)
    }

    /// A write that fails on the way (not refused) may have happened. It is
    /// logged as unknown, a label change keeps its Undo, the local index is
    /// not marked swept, and the run stops instead of failing sender after
    /// sender on a dead connection.
    @Test func aLostConnectionIsLoggedAsUnknownAndEndsTheRun() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        let context = container.mainContext
        let first = plan.items[0].cluster.address
        mailbox.beforeWrite = { _ in throw IMAPError.connectionClosed }

        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, recordRules: true, guarded: false)

        guard case .failed = executor.phase else { Issue.record("expected failure, got \(executor.phase.label)"); return }
        let actions = try context.fetch(FetchDescriptor<CleanupAction>())
        #expect(Set(actions.map(\.senderAddress)) == [first], "later senders were not attempted")
        let label = try #require(actions.first { $0.kind == .label })
        #expect(label.errorMessage?.contains("may or may not have happened") == true)
        #expect(label.isUndoable, "a label change can always be put back")
        #expect(RuleStore.all(in: context).isEmpty)
        let accountID = account.id
        let swept = try context.fetchCount(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == accountID && $0.isSweptLocally }))
        #expect(swept == 0)
    }

    /// A write cut short after some chunks: the record narrows to what the
    /// server confirmed, only those are marked swept, and the rest stay put.
    @Test func aPartialArchiveRecordsOnlyWhatWentThrough() async throws {
        let (container, account, mailbox, basePlan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        let context = container.mainContext
        var plan = basePlan
        plan.items = [basePlan.items.first { $0.cluster.pendingUIDs.count >= 2 }].compactMap { $0 }
        try #require(!plan.items.isEmpty)
        plan.items[0].disposition = .archiveOnly
        let uids = plan.items[0].cluster.pendingUIDs.sorted()
        let applied = Array(uids.prefix(uids.count / 2))
        mailbox.beforeWrite = { write in
            if write.operation == "-X-GM-LABELS" {
                throw PartialWriteError(applied: applied, reason: "NO test refusal")
            }
        }

        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, recordRules: true, guarded: false)

        let archive = try #require(try context.fetch(FetchDescriptor<CleanupAction>()).first { $0.kind == .archive })
        #expect(archive.uids == applied)
        #expect(archive.errorMessage?.hasPrefix("Only \(applied.count) of \(uids.count) went through") == true)
        #expect(archive.isUndoable, "what did go through can be put back")
        let accountID = account.id
        let swept = Set(try context.fetch(FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == accountID && $0.isSweptLocally })).map(\.uid))
        #expect(swept == Set(applied))
        #expect(executor.lastOutcome.messages == applied.count)
        #expect(executor.lastOutcome.failedSenders == 1)
        #expect(RuleStore.all(in: context).isEmpty)
    }

    /// Stop during the rules sweep of an automatic pass ends the pass there:
    /// it does not go on to read mail or report a finished tidy-up.
    @Test func stoppingATidyUpEndsThePass() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        let context = container.mainContext
        for item in plan.items { RuleStore.set(.sweep, for: item.cluster.address, in: context) }

        let engine = SyncEngine(modelContext: context)
        let executor = PlanExecutor(modelContext: context)
        let maintainer = Maintainer(modelContext: context, engine: engine, executor: executor)
        final class Reports { var texts: [String] = [] }
        let reported = Reports()
        maintainer.onFinished = { reported.texts.append($0) }
        let writes = WriteCounter()
        mailbox.beforeWrite = { _ in
            if await writes.next() == 1 { await MainActor.run { maintainer.cancel() } }
        }

        let model = StubModel()
        await maintainer.run(accounts: [account], model: model, settings: .defaults, policy: .balanced)

        #expect(maintainer.phase == .idle)
        #expect(reported.texts.isEmpty, "a stopped pass is not a finished one")
        #expect(await writes.count == 1)
        #expect(await model.requests.isEmpty, "nothing was read after Stop")
    }

    /// A Stop button that only knows the engine (the Brief's, while a tidy-up
    /// is indexing) must still end the pass before it sweeps.
    @Test func stoppingTheIndexStepOfATidyUpSweepsNothing() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        let context = container.mainContext
        for item in plan.items { RuleStore.set(.sweep, for: item.cluster.address, in: context) }

        let engine = SyncEngine(modelContext: context)
        let maintainer = Maintainer(modelContext: context, engine: engine, executor: PlanExecutor(modelContext: context))
        let writes = WriteCounter()
        mailbox.beforeWrite = { _ in _ = await writes.next() }
        mailbox.beforeOpen = { _ in await MainActor.run { engine.cancel() } }

        let model = StubModel()
        await maintainer.run(accounts: [account], model: model, settings: .defaults, policy: .balanced)

        #expect(await writes.count == 0, "no rule was applied after Stop")
        #expect(await model.requests.isEmpty)
        #expect(maintainer.phase == .idle)
    }

    /// The same for the Sweep screen's Stop, which only knows the executor:
    /// the pass must not go on to read or to the next account.
    @Test func stoppingTheSweepStepOfATidyUpEndsThePass() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        let context = container.mainContext
        for item in plan.items { RuleStore.set(.sweep, for: item.cluster.address, in: context) }

        let executor = PlanExecutor(modelContext: context)
        let maintainer = Maintainer(modelContext: context, engine: SyncEngine(modelContext: context), executor: executor)
        let writes = WriteCounter()
        mailbox.beforeWrite = { _ in
            if await writes.next() == 1 { await MainActor.run { executor.cancel() } }
        }

        let model = StubModel()
        await maintainer.run(accounts: [account], model: model, settings: .defaults, policy: .balanced)

        #expect(await writes.count == 1)
        #expect(await model.requests.isEmpty, "nothing was read after Stop")
        #expect(maintainer.phase == .idle)
    }

    /// RFC 8058 promises the one-click POST only for the URL on the message
    /// that carried the header. Mixing a URL from one message with the flag
    /// from another would POST somewhere that never agreed to it.
    @Test func unsubscribeLinkAndOneClickComeFromTheSameMessage() throws {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let account = MailAccount(displayName: "A", username: "a@x", host: "h", port: 1, kind: .generic, security: .tls)
        context.insert(account)
        func add(_ uid: UInt32, _ from: String, ageHours: Double, link: String?, post: String?) {
            context.insert(MessageHeader(
                accountID: account.id, uid: uid, mailbox: "INBOX", subject: "S\(uid)", senderName: "", senderAddress: from,
                receivedAt: Date(timeIntervalSinceNow: -ageHours * 3600), isUnread: true, isFlagged: false,
                listUnsubscribe: link, listUnsubscribePost: post, listID: nil, messageID: nil))
        }
        // Older mail offers one-click on link A; newer mail has link B only.
        add(1, "one@x.example", ageHours: 48, link: "<https://a.example/u>", post: "List-Unsubscribe=One-Click")
        add(2, "one@x.example", ageHours: 1, link: "<https://b.example/u>", post: nil)
        // The one-click header arrived on a message with no link at all.
        add(3, "two@x.example", ageHours: 48, link: "<https://c.example/u>", post: nil)
        add(4, "two@x.example", ageHours: 1, link: nil, post: "List-Unsubscribe=One-Click")
        try context.save()
        try SenderProfileBuilder.rebuild(for: account, in: context)

        let profiles = SenderProfileBuilder.assessments(for: account, in: context).map(\.cluster)
        let messages = try context.fetch(FetchDescriptor<MessageHeader>())
        let clusters = SenderClusterBuilder.build(messages: messages, contactedAddresses: [])
        for (label, set) in [("profile", profiles), ("cluster", clusters)] {
            let one = try #require(set.first { $0.address == "one@x.example" })
            #expect(one.unsubscribeValue == "<https://a.example/u>", "\(label)")
            #expect(one.supportsOneClickUnsubscribe, "\(label)")
            let two = try #require(set.first { $0.address == "two@x.example" })
            #expect(two.unsubscribeValue == "<https://c.example/u>", "\(label)")
            #expect(!two.supportsOneClickUnsubscribe, "\(label): no message carried both")
        }
    }
}
