import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

private typealias Sender = SweepReport.Sender
private typealias Write = SweepReport.Write

private func sender(_ planned: [UInt32], held: [UInt32] = [], steps: Int? = 1, writes: [Write] = [],
                    unsubscribe: SweepReport.Unsubscribe = .notRequested) -> Sender {
    Sender(address: "news@example.com", mailbox: "INBOX", planned: planned, held: held, steps: steps,
           writes: writes, unsubscribe: unsubscribe)
}

private func tally(confirmed: Int = 0, failed: Int = 0, held: Int = 0, unknown: Int = 0) -> SweepReport.Tally {
    SweepReport.Tally(confirmed: confirmed, failed: failed, held: held, unknown: unknown)
}

struct SweepReportTests {
    @Test func confirmedCountsWhatTheServerConfirmedNotWhatThePlanAsked() {
        let all = sender([1, 2, 3, 4], writes: [Write(requested: [1, 2, 3, 4], confirmed: [1, 2, 3, 4])])
        #expect(SweepReport(senders: [all], ending: .completed).tally == tally(confirmed: 4))

        let askedOnly = sender([1, 2, 3, 4], steps: 2, writes: [Write(requested: [1, 2, 3, 4], confirmed: [1, 2, 3, 4])])
        #expect(SweepReport(senders: [askedOnly], ending: .stopped).tally == tally(unknown: 4),
                "mark-read confirmed but the archive never went out")
    }

    @Test func aPartialMoveKeepsTheConfirmedPartAndFailsTheRefusedRest() {
        let refused = sender([1, 2, 3, 4], writes: [Write(requested: [1, 2, 3, 4], confirmed: [1, 2])])
        let report = SweepReport(senders: [refused], ending: .completed)
        #expect(report.tally == tally(confirmed: 2, failed: 2))
        #expect(report.classes(of: refused) == [1: .confirmed, 2: .confirmed, 3: .failed, 4: .failed])

        let cutOff = sender([1, 2, 3, 4], writes: [Write(requested: [1, 2, 3, 4], confirmed: [1, 2], unsure: [3, 4])])
        #expect(SweepReport(senders: [cutOff], ending: .interrupted).tally == tally(confirmed: 2, unknown: 2),
                "a lost acknowledgment is unknown, not failed")
    }

    @Test func aStopMidSweepLeavesUnreachedMailUnknown() {
        let done = sender([1, 2], writes: [Write(requested: [1, 2], confirmed: [1, 2])])
        let notReached = sender([3, 4, 5], steps: nil)
        #expect(SweepReport(senders: [done, notReached], ending: .stopped).tally == tally(confirmed: 2, unknown: 3))
    }

    @Test func aRefusedSweepFailsEverythingItNeverSent() {
        let notReached = [sender([1, 2], steps: nil), sender([3], steps: nil)]
        #expect(SweepReport(senders: notReached, ending: .refused).tally == tally(failed: 3))

        let refusedAtOpen = sender([1, 2], steps: 1)
        #expect(SweepReport(senders: [refusedAtOpen], ending: .refused).tally == tally(failed: 2))
    }

    @Test func heldMailIsHeldNotFailed() {
        let some = sender([1, 2, 3], held: [3], writes: [Write(requested: [1, 2], confirmed: [1, 2])])
        #expect(SweepReport(senders: [some], ending: .completed).tally == tally(confirmed: 2, held: 1))

        let all = sender([1, 2], held: [1, 2])
        #expect(SweepReport(senders: [all], ending: .completed).tally == tally(held: 2))
    }

    @Test func aLabelRefusalFailsTheMailThatWasNeverArchived() {
        let gmail = sender([1, 2, 3], steps: 2, writes: [
            Write(requested: [1, 2, 3], confirmed: [1]),
            Write(requested: [1], confirmed: [1])
        ])
        #expect(SweepReport(senders: [gmail], ending: .completed).tally == tally(confirmed: 1, failed: 2))
    }

    @Test func mailTheRunCannotAccountForIsUnknown() {
        let missingLocally = sender([1, 2, 3], writes: [Write(requested: [1, 2], confirmed: [1, 2])])
        #expect(SweepReport(senders: [missingLocally], ending: .completed).tally == tally(confirmed: 2, unknown: 1))

        let stillRunning = sender([1, 2], steps: nil)
        #expect(SweepReport(senders: [stillRunning], ending: .running).tally == tally(unknown: 2))
    }

    @Test func anUnansweredUnsubscribeIsCountedApartFromTheMail() {
        let swept = sender([1, 2], writes: [Write(requested: [1, 2], confirmed: [1, 2])], unsubscribe: .unanswered)
        let other = sender([3], writes: [Write(requested: [3], confirmed: [3])], unsubscribe: .accepted)
        let report = SweepReport(senders: [swept, other], ending: .completed)
        #expect(report.tally == tally(confirmed: 3))
        #expect(report.count(.unanswered) == 1)
        #expect(report.count(.accepted) == 1)
        #expect(report.count(.declined) == 0)
    }

    @Test func anEmptyPlanCountsNothing() {
        let report = SweepReport(senders: [], ending: .completed)
        #expect(report.tally == tally())
        #expect(report.tally.total == 0)
    }

    @Test func everyPlannedMessageLandsInExactlyOneClass() {
        let senders = [
            sender([1, 2, 3, 3], held: [1], writes: [Write(requested: [2, 3], confirmed: [2])]),
            sender([1, 2, 3, 4], steps: 2, writes: [Write(requested: [1, 2, 3, 4], confirmed: [1, 2], unsure: [3])]),
            sender([7, 8], steps: nil)
        ]
        for ending in [SweepReport.Ending.running, .completed, .stopped, .refused, .interrupted] {
            let report = SweepReport(senders: senders, ending: ending)
            let classes = senders.map { report.classes(of: $0) }
            #expect(report.tally.total == 9, "duplicate UIDs in one sender count once, and per-mailbox UIDs never merge across senders")
            #expect(classes.map(\.count).reduce(0, +) == report.tally.total)
            #expect(report.tally == senders.map { report.tally(of: $0) }.reduce(tally()) {
                tally(confirmed: $0.confirmed + $1.confirmed, failed: $0.failed + $1.failed,
                      held: $0.held + $1.held, unknown: $0.unknown + $1.unknown)
            })
        }
    }
}

/// The report the executor builds, against the in-process demo server. Demo
/// accounts never touch the Keychain.
@MainActor
@Suite(.serialized)
struct SweepReportExecutorTests {
    private func setUp(flavor: DemoMailbox.Flavor = .gmail) async throws
        -> (ModelContainer, MailAccount, DemoMailbox, CleanupPlan) {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mailbox = DemoMailbox(persona: .neglected, flavor: flavor)
        let account = MailAccount(displayName: "Demo", username: mailbox.username, host: "127.0.0.1", port: 0, kind: .demo, security: .none)
        context.insert(account); try context.save()
        DemoRegistry.shared.register(mailbox, for: account.id)

        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        guard case .finished = engine.phase else { throw IndexFailed() }

        let suggested = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context))
        let items = suggested.enabledItems.prefix(4).map {
            CleanupPlan.Item(cluster: $0.cluster, archive: true, markRead: false, disposition: .fileIntoFolders)
        }
        return (container, account, mailbox, CleanupPlan(items: items))
    }

    private struct IndexFailed: Error {}

    private func plannedCount(_ plan: CleanupPlan) -> Int {
        plan.items.map { Set($0.cluster.pendingUIDs).count }.reduce(0, +)
    }

    @Test func aCleanRunConfirmsEveryMessage() async throws {
        let (container, account, _, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        try #require(!plan.items.isEmpty)

        let executor = PlanExecutor(modelContext: container.mainContext)
        await executor.apply(plan, to: account, recordRules: false, guarded: false)

        #expect(executor.lastReport.ending == .completed)
        #expect(executor.lastReport.tally == SweepReport.Tally(confirmed: plannedCount(plan), failed: 0, held: 0, unknown: 0))
        #expect(executor.lastReport.tally.confirmed == executor.lastOutcome.messages)
        #expect(executor.lastReport.count(.notRequested) == plan.items.count)
    }

    @Test func heldMailIsCountedAsHeld() async throws {
        let (container, account, _, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        var policy = CleanupPolicy.gentle
        policy.protectRecentDays = 0
        policy.keepNewestPerSender = 1
        policy.guardTransactional = false

        let executor = PlanExecutor(modelContext: container.mainContext)
        await executor.apply(plan, to: account, recordRules: false, guarded: true, policy: policy)

        let report = executor.lastReport
        #expect(report.ending == .completed)
        #expect(report.tally.held >= plan.items.count, "each sender keeps its newest")
        #expect(report.tally.failed == 0)
        #expect(report.tally.total == plannedCount(plan))
    }

    @Test func aStopAfterTheFirstWriteLeavesTheRestUnknown() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        try #require(plan.items.count >= 2)

        let executor = PlanExecutor(modelContext: container.mainContext)
        mailbox.beforeWrite = { _ in await MainActor.run { executor.cancel() } }
        await executor.apply(plan, to: account, recordRules: false, guarded: false)

        let report = executor.lastReport
        #expect(report.ending == .stopped)
        #expect(report.tally == SweepReport.Tally(confirmed: 0, failed: 0, held: 0, unknown: plannedCount(plan)),
                "the first sender was labelled but never archived")
    }

    @Test func aRefusedLabelFailsThatSenderAndSkipsItsUnsubscribe() async throws {
        let (container, account, mailbox, basePlan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        try #require(basePlan.items.count >= 2)
        var plan = basePlan
        plan.items[0].unsubscribe = true
        let victim = plan.items[0].cluster
        let victimUIDs = Set(victim.pendingUIDs)
        mailbox.beforeWrite = { write in
            if write.operation == "+X-GM-LABELS", Set(write.uids).isSubset(of: victimUIDs) {
                throw IMAPError.commandFailed(command: "UID STORE", response: "NO test refusal")
            }
        }

        let executor = PlanExecutor(modelContext: container.mainContext)
        await executor.apply(plan, to: account, recordRules: false, guarded: false)

        let report = executor.lastReport
        let victimReport = try #require(report.senders.first)
        #expect(report.ending == .completed)
        #expect(report.tally(of: victimReport) == SweepReport.Tally(confirmed: 0, failed: victimUIDs.count, held: 0, unknown: 0))
        #expect(report.tally == SweepReport.Tally(confirmed: plannedCount(plan) - victimUIDs.count, failed: victimUIDs.count, held: 0, unknown: 0))
        #expect(victimReport.unsubscribe == .notSent)
    }

    @Test func aMailboxRefusedAtOpenFailsTheWholeSweep() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        mailbox.beforeOpen = { _ in throw IMAPError.mailboxChanged }

        let executor = PlanExecutor(modelContext: container.mainContext)
        await executor.apply(plan, to: account, recordRules: false, guarded: false)

        #expect(executor.lastReport.ending == .refused)
        #expect(executor.lastReport.tally == SweepReport.Tally(confirmed: 0, failed: plannedCount(plan), held: 0, unknown: 0))
    }

    @Test func aLostConnectionLeavesEverythingUnknown() async throws {
        let (container, account, mailbox, plan) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        mailbox.beforeWrite = { _ in throw IMAPError.connectionClosed }

        let executor = PlanExecutor(modelContext: container.mainContext)
        await executor.apply(plan, to: account, recordRules: false, guarded: false)

        #expect(executor.lastReport.ending == .interrupted)
        #expect(executor.lastReport.tally == SweepReport.Tally(confirmed: 0, failed: 0, held: 0, unknown: plannedCount(plan)))
    }

    @Test func anEmptyPlanReportsNothing() async throws {
        let (container, account, _, _) = try await setUp()
        defer { DemoRegistry.shared.remove(account.id) }

        let executor = PlanExecutor(modelContext: container.mainContext)
        await executor.apply(CleanupPlan(items: []), to: account)

        #expect(executor.lastReport.senders.isEmpty)
        #expect(executor.lastReport.ending == .completed)
        #expect(executor.lastReport.tally.total == 0)
    }
}
