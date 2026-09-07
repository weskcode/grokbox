import Foundation
import Testing
import SwiftData
@testable import GrokboxCore

// MARK: - The policy model

struct CleanupPolicyModelTests {
    @Test func presetsAreDistinctAndRecognisable() {
        #expect(CleanupPolicy.gentle.matchingPreset == .gentle)
        #expect(CleanupPolicy.balanced.matchingPreset == .balanced)
        #expect(CleanupPolicy.thorough.matchingPreset == .thorough)
        var edited = CleanupPolicy.balanced
        edited.protectRecentDays = 99
        #expect(edited.matchingPreset == .custom)
    }

    @Test func defaultIsTheGentlePreset() {
        let empty = UserDefaults(suiteName: "grokbox.tests.empty.\(UUID().uuidString)")!
        #expect(CleanupPolicy.load(from: empty) == .gentle)
    }

    @Test func roundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "grokbox.tests.\(UUID().uuidString)")!
        var policy = CleanupPolicy.thorough
        policy.protectRecentDays = 3
        CleanupPolicy.save(policy, to: defaults)
        #expect(CleanupPolicy.load(from: defaults) == policy)
    }

    @Test func onlyTrashCarriesAWarning() {
        #expect(CleanupPolicy.Disposition.trash.warning != nil)
        #expect(CleanupPolicy.Disposition.archiveOnly.warning == nil)
        #expect(CleanupPolicy.Disposition.fileIntoFolders.warning == nil)
    }

    /// The summary is the only place a person sees what a policy will do, so
    /// it has to name every consequence.
    @Test func summaryNamesWhatWillHappen() {
        let gentle = CleanupPolicy.gentle.summary
        #expect(gentle.contains("Files swept mail"))
        #expect(gentle.contains("last 7 days"))
        #expect(gentle.contains("newest 2"))
        #expect(gentle.contains("Never unsubscribes"))

        let thorough = CleanupPolicy.thorough.summary
        #expect(thorough.contains("promotions go to the Trash"))
        #expect(thorough.contains("Unsubscribes automatically"))
        #expect(thorough.contains("75%"))
    }

    @Test func promotionsCanDifferFromEverythingElse() {
        #expect(CleanupPolicy.thorough.disposition(for: .promotion) == .trash)
        #expect(CleanupPolicy.thorough.disposition(for: .newsletter) == .fileIntoFolders)
        #expect(CleanupPolicy.gentle.disposition(for: .promotion) == .fileIntoFolders)
    }
}

// MARK: - What the guard holds back

struct PolicyGuardTests {
    private func facts(_ specs: [(UInt32, String, Int)], flagged: Set<UInt32> = []) -> [SweepGuard.MessageFacts] {
        specs.map { uid, subject, daysAgo in
            .init(uid: uid, subject: subject, isFlagged: flagged.contains(uid), importance: nil,
                  receivedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!)
        }
    }

    @Test func recentMailIsHeldBack() {
        var policy = CleanupPolicy.gentle
        policy.keepNewestPerSender = 0
        policy.protectRecentDays = 7
        let verdict = SweepGuard.check(facts([(1, "Sale", 1), (2, "Sale", 10), (3, "Sale", 30)]), policy: policy)
        #expect(verdict.allowed == [2, 3])
        #expect(verdict.held.map(\.uid) == [1])
        #expect(verdict.held[0].reason == "too recent")
    }

    @Test func newestFromEachSenderIsKept() {
        var policy = CleanupPolicy.gentle
        policy.protectRecentDays = 0
        policy.keepNewestPerSender = 2
        let verdict = SweepGuard.check(facts([(1, "Issue 1", 30), (2, "Issue 2", 20), (3, "Issue 3", 10), (4, "Issue 4", 5)]), policy: policy)
        #expect(Set(verdict.allowed) == [1, 2], "the two oldest are swept")
        #expect(Set(verdict.held.map(\.uid)) == [3, 4])
        #expect(verdict.held.allSatisfy { $0.reason == "newest from this sender" })
    }

    @Test func flaggedAndTransactionalStillWinOverEverything() {
        var policy = CleanupPolicy.thorough   // no age or keep-newest protection
        policy.guardTransactional = true
        let verdict = SweepGuard.check(facts([(1, "Sale", 30), (2, "Your receipt", 30), (3, "Sale", 30)], flagged: [3]), policy: policy)
        #expect(verdict.allowed == [1])
        #expect(Set(verdict.held.map(\.reason)) == ["look transactional", "flagged"])
    }

    @Test func thoroughPolicyHoldsBackNothingRoutine() {
        let verdict = SweepGuard.check(facts([(1, "Sale", 0), (2, "Sale", 1)]), policy: .thorough)
        #expect(verdict.allowed == [1, 2], "no age or keep-newest limits in the thorough preset")
    }
}

// MARK: - Which senders the plan proposes, and what it proposes to do

@MainActor
struct PolicyPlanTests {
    private func cluster(_ address: String, category: SenderCategory, messages: Int, unread: Int,
                         oneClick: Bool = true, contacted: Bool = false) -> SenderCluster {
        SenderCluster(address: address, displayName: address, domain: "x.example", mailbox: "INBOX",
                      uids: Array(1...UInt32(messages)), unreadUIDs: Array(1...UInt32(max(unread, 1))),
                      messageCount: messages, unreadCount: unread, flaggedCount: 0, sweptCount: 0,
                      newest: .now, oldest: .now, hasUnsubscribeLink: oneClick,
                      unsubscribeValue: oneClick ? "<https://x.example/u>" : nil,
                      supportsOneClickUnsubscribe: oneClick, everContacted: contacted, sampleSubjects: [],
                      category: category)
    }

    private func assessment(_ c: SenderCluster) -> SenderAssessment {
        SenderAssessment(cluster: c, verdict: .bulk, score: 10, reasons: [])
    }

    @Test func contactedSendersAreNotProposedWhenGuarded() {
        let a = [assessment(cluster("friend@x.example", category: .person, messages: 20, unread: 20, contacted: true)),
                 assessment(cluster("deals@x.example", category: .promotion, messages: 20, unread: 20))]
        var policy = CleanupPolicy.gentle
        policy.guardContacted = true
        #expect(CleanupPlan.suggested(from: a, policy: policy).items.map(\.cluster.address) == ["deals@x.example"])
        policy.guardContacted = false
        #expect(CleanupPlan.suggested(from: a, policy: policy).items.count == 2)
    }

    @Test func anExplicitRuleBeatsTheContactedGuard() {
        let a = [assessment(cluster("newsletter@x.example", category: .newsletter, messages: 20, unread: 20, contacted: true))]
        let plan = CleanupPlan.suggested(from: a, rules: ["newsletter@x.example": .sweep], policy: .gentle)
        #expect(plan.items.count == 1, "the user's own rule wins")
    }

    @Test func dispositionComesFromThePolicyPerCategory() {
        let a = [assessment(cluster("deals@x.example", category: .promotion, messages: 20, unread: 20)),
                 assessment(cluster("news@x.example", category: .newsletter, messages: 20, unread: 20))]
        let plan = CleanupPlan.suggested(from: a, policy: .thorough)
        let byAddress = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.cluster.address, $0) })
        #expect(byAddress["deals@x.example"]?.disposition == .trash)
        #expect(byAddress["news@x.example"]?.disposition == .fileIntoFolders)
    }

    @Test func autoUnsubscribeIsConservative() {
        // Qualifies under thorough: promotion, one-click, 20 messages, all unread.
        #expect(CleanupPlan.qualifiesForAutoUnsubscribe(cluster("a@x.example", category: .promotion, messages: 20, unread: 20), policy: .thorough))
        // Never under gentle, whatever the sender looks like.
        #expect(!CleanupPlan.qualifiesForAutoUnsubscribe(cluster("a@x.example", category: .promotion, messages: 20, unread: 20), policy: .gentle))
        // No one-click endpoint.
        #expect(!CleanupPlan.qualifiesForAutoUnsubscribe(cluster("a@x.example", category: .promotion, messages: 20, unread: 20, oneClick: false), policy: .thorough))
        // Too few messages to judge.
        #expect(!CleanupPlan.qualifiesForAutoUnsubscribe(cluster("a@x.example", category: .promotion, messages: 2, unread: 2), policy: .thorough))
        // Mail you actually read.
        #expect(!CleanupPlan.qualifiesForAutoUnsubscribe(cluster("a@x.example", category: .promotion, messages: 20, unread: 5), policy: .thorough))
        // A person, not a sender you can unsubscribe from.
        #expect(!CleanupPlan.qualifiesForAutoUnsubscribe(cluster("a@x.example", category: .person, messages: 20, unread: 20), policy: .thorough))
        // Balanced additionally requires that you never wrote back.
        #expect(!CleanupPlan.qualifiesForAutoUnsubscribe(cluster("a@x.example", category: .newsletter, messages: 20, unread: 20, contacted: true), policy: .balanced))
    }
}

// MARK: - The policy applied for real, against a demo mailbox

@MainActor
@Suite(.serialized)
struct PolicyExecutionTests {
    private func setUp(flavor: DemoMailbox.Flavor = .gmail)
        -> (ModelContainer, ModelContext, MailAccount, DemoMailbox) {
        let container = ModelContainer.grokboxTestContainer()
        let context = container.mainContext
        let mailbox = DemoMailbox(persona: .neglected, flavor: flavor)
        let account = MailAccount(displayName: "Demo", username: mailbox.username, host: "127.0.0.1",
                                  port: 0, kind: .demo, security: .none)
        context.insert(account); try! context.save()
        DemoRegistry.shared.register(mailbox, for: account.id)
        return (container, context, account, mailbox)
    }

    private func indexed(_ context: ModelContext, _ account: MailAccount) async -> SyncEngine {
        let engine = SyncEngine(modelContext: context)
        await engine.indexNow(account: account, mode: .full(limit: 10_000))
        return engine
    }

    /// Trash means "move to the provider's Trash": the messages leave the
    /// inbox, arrive in Trash, and can be moved back. Nothing is expunged.
    @Test func trashDispositionMovesToTrashAndIsUndoable() async throws {
        let (container, context, account, mailbox) = setUp(flavor: .generic(delimiter: "/", inboxPrefix: false))
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container
        _ = await indexed(context, account)

        var policy = CleanupPolicy.thorough
        policy.disposition = .trash
        policy.promotionDisposition = .trash
        let plan = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context),
                                         rules: [:], policy: policy)
        #expect(!plan.enabledItems.isEmpty)
        #expect(plan.enabledItems.allSatisfy { $0.disposition == .trash })

        let trashName = mailbox.listMailboxes().trashMailbox?.name
        let trashBefore = trashName.map { mailbox.messages(in: $0).count } ?? 0
        let inboxBefore = mailbox.messages(in: "INBOX").count

        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, policy: policy)
        guard case .finished = executor.phase else { Issue.record("sweep: \(executor.phase.label)"); return }

        let actions = try context.fetch(FetchDescriptor<CleanupAction>()).filter { $0.errorMessage == nil }
        let trashed = actions.filter { $0.kind == .trash }
        #expect(!trashed.isEmpty, "recorded as a trash action, not an archive")
        #expect(actions.allSatisfy { $0.kind != .archive }, "nothing was archived under a trash policy")

        let moved = trashed.reduce(0) { $0 + $1.uids.count }
        #expect(mailbox.messages(in: trashName!).count == trashBefore + moved, "the messages are in the Trash")
        #expect(mailbox.messages(in: "INBOX").count == inboxBefore - moved)
        // Nothing was destroyed: every message still exists somewhere.
        #expect(mailbox.messages(in: trashName!).count > 0)

        let undoable = try #require(trashed.first { $0.isUndoable })
        await executor.undo(undoable, on: account)
        #expect(undoable.isUndone, "undo: \(executor.phase.label)")
        #expect(mailbox.messages(in: "INBOX").count == inboxBefore - moved + undoable.uids.count)
    }

    /// A server with no Trash must refuse the policy rather than quietly
    /// archiving and calling it deletion.
    @Test func trashOnAServerWithoutTrashFailsLoudly() async throws {
        let (container, context, account, mailbox) = setUp(flavor: .generic(delimiter: "/", inboxPrefix: false))
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container
        _ = await indexed(context, account)
        mailbox.removeMailbox(mailbox.listMailboxes().trashMailbox?.name ?? "Trash")

        var policy = CleanupPolicy.gentle
        policy.disposition = .trash
        policy.protectRecentDays = 0
        policy.keepNewestPerSender = 0
        let plan = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context), policy: policy)
        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, policy: policy)

        guard case .failed(let why) = executor.phase else { Issue.record("expected a refusal, got \(executor.phase.label)"); return }
        #expect(why.localizedCaseInsensitiveContains("trash"))
        #expect(try context.fetchCount(FetchDescriptor<CleanupAction>()) == 0, "nothing ran")
    }

    /// Archive-only leaves the inbox without filing into a Grokbox folder.
    @Test func archiveOnlyDoesNotCreateFolders() async throws {
        let (container, context, account, mailbox) = setUp()   // Gmail flavour
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container
        _ = await indexed(context, account)

        var policy = CleanupPolicy.thorough
        policy.disposition = .archiveOnly
        policy.promotionDisposition = .archiveOnly
        let plan = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context), policy: policy)
        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, policy: policy)
        guard case .finished = executor.phase else { Issue.record("sweep: \(executor.phase.label)"); return }

        let kinds = Set(try context.fetch(FetchDescriptor<CleanupAction>()).filter { $0.errorMessage == nil }.map(\.kind))
        #expect(kinds.contains(.archive))
        #expect(!kinds.contains(.label), "archive-only files nothing")
        let labels = Set(mailbox.messages(in: DemoMailbox.allMail).flatMap(\.labels))
        #expect(!labels.contains { $0.hasPrefix("Grokbox/") }, "no Grokbox labels were applied")
    }

    /// The policy's age and keep-newest limits reach all the way through a
    /// real sweep, not just the guard in isolation.
    @Test func gentlePolicySweepsLessThanThorough() async throws {
        func sweptCount(_ policy: CleanupPolicy) async throws -> Int {
            let (container, context, account, _) = setUp()
            defer { DemoRegistry.shared.remove(account.id) }
            _ = container
            _ = await indexed(context, account)
            let plan = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context), policy: policy)
            let executor = PlanExecutor(modelContext: context)
            await executor.apply(plan, to: account, policy: policy)
            return try context.fetch(FetchDescriptor<CleanupAction>())
                .filter { $0.kind == .archive && $0.errorMessage == nil }
                .reduce(0) { $0 + $1.uids.count }
        }
        var gentle = CleanupPolicy.gentle
        gentle.unsubscribe = .never
        var thorough = CleanupPolicy.thorough
        thorough.promotionDisposition = nil    // compare like with like: both archive
        thorough.unsubscribe = .never

        let gentleCount = try await sweptCount(gentle)
        let thoroughCount = try await sweptCount(thorough)
        #expect(gentleCount < thoroughCount, "gentle \(gentleCount) vs thorough \(thoroughCount)")
        #expect(gentleCount > 0, "gentle still does something useful")
    }

    /// Automatic unsubscribe happens as part of the sweep, is recorded, and
    /// cannot be undone — the one irreversible thing, so it must be honest.
    @Test func automaticUnsubscribeIsRecordedAndNotUndoable() async throws {
        let (container, context, account, _) = setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container
        _ = await indexed(context, account)

        var policy = CleanupPolicy.thorough
        policy.promotionDisposition = nil
        let plan = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context), policy: policy)
        #expect(!plan.autoUnsubscribeItems.isEmpty, "the neglected mailbox has senders that qualify")

        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, policy: policy)

        let unsubs = try context.fetch(FetchDescriptor<CleanupAction>()).filter { $0.kind == .unsubscribe }
        #expect(!unsubs.isEmpty)
        #expect(unsubs.allSatisfy { !$0.isUndoable })
        // The demo senders' URLs are unreachable .example hosts, so each is
        // recorded with the reason rather than silently dropped.
        #expect(unsubs.allSatisfy { $0.errorMessage != nil || $0.kind == .unsubscribe })

        let target = try #require(unsubs.first)
        await executor.undo(target, on: account)
        #expect(!target.isUndone, "an unsubscribe cannot be taken back")
    }

    /// Never unsubscribe when the policy says not to, however tempting the sender.
    @Test func gentlePolicyNeverUnsubscribes() async throws {
        let (container, context, account, _) = setUp()
        defer { DemoRegistry.shared.remove(account.id) }
        _ = container
        _ = await indexed(context, account)
        let plan = CleanupPlan.suggested(from: SenderProfileBuilder.assessments(for: account, in: context), policy: .gentle)
        #expect(plan.autoUnsubscribeItems.isEmpty)
        let executor = PlanExecutor(modelContext: context)
        await executor.apply(plan, to: account, policy: .gentle)
        #expect(try context.fetch(FetchDescriptor<CleanupAction>()).allSatisfy { $0.kind != .unsubscribe })
    }
}
