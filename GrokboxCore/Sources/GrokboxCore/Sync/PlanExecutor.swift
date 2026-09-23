import Foundation
import SwiftData

/// The only thing in Grokbox that writes to a mailbox.
///
/// Every mutation is preceded by a `CleanupAction` record — written and saved
/// *before* the IMAP command goes out — so a crash mid-run still leaves an
/// accurate log, and undo always has something to read from. The record starts
/// out marked as interrupted and not undoable; only the server's confirmation
/// clears the one and sets the other.
@MainActor
@Observable
public final class PlanExecutor {
    public enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case applying(done: Int, total: Int)
        case undoing
        case finished(String)
        case failed(String)

        public var isRunning: Bool {
            switch self {
            case .idle, .finished, .failed: false
            default: true
            }
        }

        public var label: String {
            switch self {
            case .idle: "Ready"
            case .connecting: "Connecting…"
            case .applying(let done, let total): "Applying — \(done) of \(total) senders"
            case .undoing: "Undoing…"
            case .finished(let message): message
            case .failed(let message): message
            }
        }
    }

    /// What the last `apply` actually did, as confirmed by the server. The
    /// maintainer reports this rather than what the plan intended.
    public struct Outcome: Equatable, Sendable {
        public var messages = 0
        public var senders = 0
        public var failedSenders = 0
        public var stopped = false
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastOutcome = Outcome()
    private var activeProvider: (any MailProvider)?
    /// The generation the connected run started under.
    private var activeRun = 0
    /// Bumped by `cancel()`. A run compares it with the value it started
    /// under, so a Stop reaches the run it was meant for even when nothing in
    /// that run is a cancellable task, and never reaches a later one.
    private var generation = 0
    /// Set by `run` when a write failed on the way rather than being refused:
    /// the connection is gone, and every later write would fail the same way.
    private var lostConnection: (any Error)?

    /// How long Stop lets a write that is already on the wire finish.
    static let stopGrace: Duration = .seconds(5)

    /// Stops a sweep or an undo in progress. The run stops at its next check,
    /// between writes, and logs out itself. Nothing is sent on the connection
    /// here: a LOGOUT while a write waits for its reply can consume that reply,
    /// and a move the server made would be recorded as a failure. Only a write
    /// still hanging after `stopGrace`, on a server that has gone quiet, gets
    /// its connection cut.
    public func cancel() {
        generation += 1
        guard activeProvider != nil else { return }
        let stopped = generation
        Task { [weak self] in
            try? await Task.sleep(for: Self.stopGrace)
            guard let self, let provider = self.activeProvider, self.activeRun < stopped else { return }
            self.activeProvider = nil
            await provider.abort()
        }
    }
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Apply

    /// Applies every enabled item. When `recordRules` is set, each sender gets a
    /// `sweep` rule so future maintenance handles them without asking.
    public func apply(_ plan: CleanupPlan, to account: MailAccount, recordRules: Bool = true, guarded: Bool = true,
                      policy: CleanupPolicy = .current) async {
        guard !phase.isRunning else { return }
        lastOutcome = Outcome()
        lostConnection = nil
        let items = plan.enabledItems
        guard !items.isEmpty else { return }
        let token = generation
        // A sender's rule is written only once that sender's mail has actually
        // been dealt with. Written up front, a sweep that failed or was stopped
        // would still leave rules behind, and the next tidy-up would sweep the
        // very senders the user stopped.
        let recordRule = { (address: String) in
            if recordRules { RuleStore.set(.sweep, for: address, in: self.modelContext) }
        }

        phase = .connecting
        do {
            let provider = try await MailProviderFactory.connect(to: account)
            activeProvider = provider
            activeRun = token
            defer { activeProvider = nil; Task { await provider.finish() } }
            // Stop pressed while connecting: nothing may be created or moved.
            try checkStopped(token)

            let capabilities = await provider.capabilities
            let isGmail = capabilities.supportsGmailExtensions
            let mailboxes = try await provider.discoverMailboxes()
            // Trash is resolved once, before anything runs: a policy that
            // cannot find the Trash must fail loudly rather than archive
            // quietly and call it deletion.
            var trashName: String?
            if plan.enabledItems.contains(where: { $0.disposition == .trash }) {
                guard let trash = mailboxes.trashMailbox else {
                    phase = .failed("This server does not expose a Trash mailbox, so Grokbox cannot move mail there. Choose a different disposition in Settings.")
                    return
                }
                trashName = trash.name
            }
            var archiveName: String?
            if !isGmail, plan.enabledItems.contains(where: { $0.disposition == .archiveOnly }) {
                guard let archive = mailboxes.archiveMailbox else {
                    phase = .failed("This server has no Archive mailbox, so 'Archive only' cannot be applied. Choose 'File into folders' in Settings.")
                    return
                }
                archiveName = archive.name
            }
            // Folder names as this server spells them: its delimiter, its
            // namespace prefix, modified UTF-7. Gmail takes the logical name.
            var serverFolder: [String: String] = [:]
            if !isGmail, items.contains(where: \.archive) {
                guard capabilities.supportsMove else {
                    phase = .failed("This server does not support MOVE, so Grokbox cannot archive safely. Mark-read still works.")
                    return
                }
                for folder in Set(items.filter { $0.disposition == .fileIntoFolders }.map(\.folder)) {
                    try checkStopped(token)
                    let name = mailboxes.serverName(forLogical: folder)
                    serverFolder[folder] = name
                    try await provider.ensureMailbox(name)
                }
            }

            var openMailbox: String?
            var openValidity: UInt32 = 0
            var unsubscribed = Set<String>()
            var unsubscribeCount = 0
            var done = 0
            var touched = 0
            var failedSenders = 0
            var succeeded: [String] = []

            let keepTransactional = policy.guardTransactional
            var heldTotal = 0

            for item in items {
                try checkStopped(token)
                // Message-level safety net over the sender-level decision.
                _ = keepTransactional
                let verdict = guarded
                    ? SweepGuard.check(facts(for: item.cluster.pendingUIDs, in: account), policy: policy)
                    : SweepGuard.Verdict(allowed: item.cluster.pendingUIDs, held: [])
                let uids = verdict.allowed
                heldTotal += verdict.held.count
                guard !uids.isEmpty else {
                    // Everything was held, which is the guard working, not a
                    // failure: the decision about the sender still stands.
                    recordRule(item.cluster.address)
                    continue
                }

                if openMailbox != item.cluster.mailbox {
                    let status = try await provider.openReadWrite(item.cluster.mailbox)
                    try guardUIDValidity(status, account: account, mailbox: item.cluster.mailbox)
                    openMailbox = item.cluster.mailbox
                    openValidity = status.uidValidity ?? 0
                }

                var itemFailed = false
                var confirmed: [UInt32] = []

                if item.markRead {
                    let action = record(.markRead, for: item, uids: uids, account: account, uidValidity: openValidity)
                    confirmed = await run(action) {
                        try await provider.setFlags(uids: uids, .add, flags: ["\\Seen"])
                        return nil
                    }
                    itemFailed = itemFailed || action.errorMessage != nil
                }

                if item.archive {
                    try checkStopped(token)
                    confirmed = []
                    switch item.disposition {
                    case .trash:
                        // Deliberately a MOVE to the provider's Trash, never a
                        // \\Deleted flag and never EXPUNGE. The provider empties
                        // it on its own schedule; until then this is undoable.
                        let target = trashName ?? "Trash"
                        let action = record(.trash, for: item, uids: uids, account: account, labelName: target, uidValidity: openValidity)
                        action.heldUIDs = verdict.held.map(\.uid)
                        action.heldSummary = verdict.summary
                        action.targetMailbox = target
                        confirmed = await run(action) { try await provider.move(uids: uids, to: target) }
                        itemFailed = itemFailed || action.errorMessage != nil

                    case .archiveOnly where isGmail:
                        let archive = record(.archive, for: item, uids: uids, account: account, uidValidity: openValidity)
                        archive.heldUIDs = verdict.held.map(\.uid)
                        archive.heldSummary = verdict.summary
                        confirmed = await run(archive) {
                            try await provider.setGmailLabels(uids: uids, .remove, labels: ["\\Inbox"])
                            return nil
                        }
                        itemFailed = itemFailed || archive.errorMessage != nil

                    case .archiveOnly:
                        let target = archiveName ?? "Archive"
                        let archive = record(.archive, for: item, uids: uids, account: account, labelName: target, uidValidity: openValidity)
                        archive.heldUIDs = verdict.held.map(\.uid)
                        archive.heldSummary = verdict.summary
                        archive.targetMailbox = target
                        confirmed = await run(archive) { try await provider.move(uids: uids, to: target) }
                        itemFailed = itemFailed || archive.errorMessage != nil

                    case .fileIntoFolders where isGmail:
                        let label = record(.label, for: item, uids: uids, account: account, labelName: item.folder, uidValidity: openValidity)
                        let labelled = await run(label) {
                            try await provider.setGmailLabels(uids: uids, .add, labels: [item.folder])
                            return nil
                        }
                        itemFailed = itemFailed || label.errorMessage != nil
                        // Only what got the folder label leaves the inbox. Taking
                        // \Inbox off mail whose label failed would file it nowhere.
                        guard !labelled.isEmpty else { break }
                        try checkStopped(token)
                        let archive = record(.archive, for: item, uids: labelled, account: account, uidValidity: openValidity)
                        archive.heldUIDs = verdict.held.map(\.uid)
                        archive.heldSummary = verdict.summary
                        confirmed = await run(archive) {
                            try await provider.setGmailLabels(uids: labelled, .remove, labels: ["\\Inbox"])
                            return nil
                        }
                        itemFailed = itemFailed || archive.errorMessage != nil

                    case .fileIntoFolders:
                        // MOVE gives the messages new UIDs in the target. Servers with
                        // UIDPLUS report them (COPYUID), and that is what makes the
                        // move undoable; without it the action is recorded as final.
                        let target = serverFolder[item.folder] ?? item.folder
                        let archive = record(.archive, for: item, uids: uids, account: account, labelName: item.folder, uidValidity: openValidity)
                        archive.heldUIDs = verdict.held.map(\.uid)
                        archive.heldSummary = verdict.summary
                        archive.targetMailbox = target
                        confirmed = await run(archive) { try await provider.move(uids: uids, to: target) }
                        itemFailed = itemFailed || archive.errorMessage != nil
                    }
                    if !confirmed.isEmpty { markSwept(uids: confirmed, in: account, swept: true, address: item.cluster.address) }
                }

                // The unsubscribe goes last, and only if the sweep itself
                // worked: telling a sender to stop is not undoable, so it must
                // never happen for mail that is still sitting in the inbox, nor
                // after the user pressed Stop.
                if item.unsubscribe, !itemFailed, !isStopped(token), unsubscribed.insert(item.cluster.address).inserted {
                    let action = record(.unsubscribe, for: item, uids: [], account: account,
                                        labelName: item.cluster.address, uidValidity: 0)
                    let outcome = await UnsubscribeService.unsubscribe(from: item.cluster)
                    switch outcome {
                    case .unsubscribed:
                        action.errorMessage = nil
                        unsubscribeCount += 1
                    case .openInBrowser, .requiresEmail:
                        // Automatic mode is one-click only. Anything needing a
                        // browser or an email is left for the user to decide.
                        action.errorMessage = "Needs a browser; left for you in Senders."
                    case .failed(let why):
                        action.errorMessage = why
                    }
                }

                touched += confirmed.count
                if itemFailed {
                    failedSenders += 1
                } else {
                    done += 1
                    succeeded.append(item.cluster.address)
                    recordRule(item.cluster.address)
                }
                lastOutcome = Outcome(messages: touched, senders: done, failedSenders: failedSenders)
                phase = .applying(done: done + failedSenders, total: items.count)
                try modelContext.save()
                if let lostConnection { throw lostConnection }
            }
            // A Stop that landed during the last sender still counts as a Stop.
            try checkStopped(token)

            RuleStore.bumpApplied(for: succeeded, in: modelContext)
            let heldNote = heldTotal > 0 ? ", held \(heldTotal) for you" : ""
            let unsubNote = unsubscribeCount > 0 ? ", unsubscribed from \(unsubscribeCount)" : ""
            let swept = "Swept \(touched.formatted()) messages from \(done) senders\(heldNote)\(unsubNote)"
            if failedSenders > 0 {
                phase = .failed("\(swept). \(failedSenders) \(failedSenders == 1 ? "sender" : "senders") failed; see Activity.")
            } else {
                phase = .finished(swept)
            }
        } catch where error is CancellationError || isStopped(token) {
            // Includes a write cut off by Stop's grace period: that is the Stop.
            try? modelContext.save()
            lastOutcome.stopped = true
            let o = lastOutcome
            phase = .finished("Stopped. Swept \(o.messages.formatted()) messages from \(o.senders) senders; the rest were left alone.")
        } catch {
            try? modelContext.save()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Archives one message from the Brief. Does not write a sender rule — a
    /// single "done" is not a decision about the sender.
    public func sweep(_ message: MessageHeader, in account: MailAccount) async {
        await sweep([message], in: account)
    }

    /// Archives a Brief thread as one run, so a single Stop ends all of it.
    public func sweep(_ messages: [MessageHeader], in account: MailAccount) async {
        let items = messages.map { message in
            CleanupPlan.Item(cluster: SenderCluster(
                address: message.senderAddress, displayName: message.senderName.isEmpty ? message.senderAddress : message.senderName,
                domain: message.senderDomain, mailbox: message.mailbox,
                uids: [message.uid], unreadUIDs: message.isUnread ? [message.uid] : [],
                messageCount: 1, unreadCount: message.isUnread ? 1 : 0, flaggedCount: 0, sweptCount: 0,
                newest: message.receivedAt, oldest: message.receivedAt,
                hasUnsubscribeLink: false, unsubscribeValue: nil, supportsOneClickUnsubscribe: false,
                everContacted: false, sampleSubjects: [message.subject]
            ))
        }
        await apply(CleanupPlan(items: items), to: account, recordRules: false, guarded: false)
    }

    // MARK: - Undo

    public func undo(_ action: CleanupAction, on account: MailAccount) async {
        guard !phase.isRunning, action.isUndoable, !action.isUndone else { return }
        phase = .undoing
        do {
            let provider = try await MailProviderFactory.connect(to: account)
            activeProvider = provider
            defer { activeProvider = nil; Task { await provider.finish() } }

            switch action.kind {
            case .unsubscribe:
                throw IMAPError.commandFailed(command: "UNDO", response: "An unsubscribe cannot be taken back. Re-subscribe on the sender's own site if you want their mail again.")
            case .trash, .archive where action.targetMailbox != nil && !action.targetUIDs.isEmpty:
                // A MOVE on a plain server: bring the messages back from the
                // folder they went to. The guard runs against *that* mailbox.
                let target = action.targetMailbox!
                let status = try await provider.openReadWrite(target)
                if let live = status.uidValidity, action.targetUIDValidity != 0, live != action.targetUIDValidity {
                    throw IMAPError.mailboxChanged
                }
                try await provider.move(uids: action.targetUIDs, to: action.mailbox)
                markSwept(uids: action.uids, in: account, swept: false, address: action.senderAddress)
            case .archive:
                let status = try await provider.openReadWrite(action.mailbox)
                try guardUndo(status, action: action, account: account)
                try await provider.setGmailLabels(uids: action.uids, .add, labels: ["\\Inbox"])
                markSwept(uids: action.uids, in: account, swept: false, address: action.senderAddress)
            case .markRead:
                let status = try await provider.openReadWrite(action.mailbox)
                try guardUndo(status, action: action, account: account)
                try await provider.setFlags(uids: action.uids, .remove, flags: ["\\Seen"])
            case .label:
                let status = try await provider.openReadWrite(action.mailbox)
                try guardUndo(status, action: action, account: account)
                if let label = action.labelName {
                    try await provider.setGmailLabels(uids: action.uids, .remove, labels: [label])
                }
            }
            action.undoneAt = Date()
            try modelContext.save()
            phase = .finished("Undid \(action.kind.label.lowercased()) for \(action.senderName)")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Plumbing

    /// Refuses to write if the server has renumbered the mailbox since we
    /// indexed it: our UIDs would point at the wrong messages.
    /// Undo's guard. Compares the validity recorded **on the action** against
    /// what the server reports now, so a mailbox that was renumbered after the
    /// sweep is caught even though an index pass has since refreshed the
    /// snapshot. Actions recorded before this was tracked (`uidValidity == 0`)
    /// fall back to the snapshot check, which is no weaker than the old
    /// behaviour but cannot detect a renumber that an index has already absorbed.
    private func guardUndo(_ status: MailboxStatus, action: CleanupAction, account: MailAccount) throws {
        guard let live = status.uidValidity else { return }
        guard action.uidValidity != 0 else {
            try guardUIDValidity(status, account: account, mailbox: action.mailbox)
            return
        }
        if action.uidValidity != live { throw IMAPError.mailboxChanged }
    }

    private func guardUIDValidity(_ status: MailboxStatus, account: MailAccount, mailbox: String) throws {
        guard let validity = status.uidValidity else { return }
        let key = MailboxSnapshot.key(accountID: account.id, mailbox: mailbox)
        let snapshot = try? modelContext.fetch(FetchDescriptor<MailboxSnapshot>(predicate: #Predicate { $0.key == key })).first
        if let snapshot, snapshot.uidValidity != validity {
            throw IMAPError.mailboxChanged
        }
    }

    private func record(
        _ kind: ActionKind,
        for item: CleanupPlan.Item,
        uids: [UInt32],
        account: MailAccount,
        labelName: String? = nil,
        uidValidity: UInt32 = 0
    ) -> CleanupAction {
        let action = CleanupAction(
            accountID: account.id,
            kind: kind,
            senderAddress: item.cluster.address,
            senderName: item.cluster.displayName,
            mailbox: item.cluster.mailbox,
            uids: uids,
            labelName: labelName,
            isUndoable: false,
            uidValidity: uidValidity
        )
        // Saved in this state before the command goes out, so if the app dies
        // mid-command, Activity says so instead of showing a clean success.
        action.errorMessage = Self.interrupted
        modelContext.insert(action)
        try? modelContext.save()
        return action
    }

    static let interrupted = "Interrupted before the server confirmed it."

    /// Runs one server write for `action` and settles the record from what the
    /// server confirmed. Returns the UIDs that actually changed: all of them,
    /// the chunks before a failure, or none. The operation returns the MOVE
    /// result for a move and nil for a flag or label change.
    private func run(_ action: CleanupAction, _ operation: () async throws -> MoveResult?) async -> [UInt32] {
        let requested = action.uids
        // A flag or label change can be reversed whether or not it landed, so
        // it is undoable from the moment it is sent; if the app dies before
        // the reply, Undo is still there. A move (it has a target) can only
        // be reversed once the server says where the messages went.
        let reversibleIfUnsure = action.targetMailbox == nil
        action.isUndoable = reversibleIfUnsure
        try? modelContext.save()
        do {
            settle(action, confirmed: requested, moved: try await operation())
            return requested
        } catch let partial as PartialWriteError {
            settle(action, confirmed: partial.applied, moved: partial.moved)
            if partial.unsure.isEmpty {
                action.errorMessage = "Only \(partial.applied.count) of \(requested.count) went through. \(partial.reason)"
            } else {
                action.uids = partial.applied + partial.unsure
                action.errorMessage = Self.unsure(partial.reason)
                action.isUndoable = reversibleIfUnsure
                lostConnection = partial
            }
            return partial.applied
        } catch let error as IMAPError where error.isRefusal {
            action.errorMessage = error.localizedDescription
            action.isUndoable = false
            return []
        } catch {
            action.errorMessage = Self.unsure(error.localizedDescription)
            action.isUndoable = reversibleIfUnsure
            lostConnection = error
            return []
        }
    }

    static func unsure(_ reason: String) -> String {
        "The connection was lost before the server confirmed this, so it may or may not have happened. \(reason)"
    }

    /// Narrows the record to what the server confirmed. A flag or label change
    /// is undoable once confirmed; a MOVE only when the server said where the
    /// messages went (COPYUID), because undo has to find them there.
    private func settle(_ action: CleanupAction, confirmed: [UInt32], moved: MoveResult?) {
        action.uids = confirmed
        action.errorMessage = nil
        guard !confirmed.isEmpty else { action.isUndoable = false; return }
        if let moved {
            if let newUIDs = moved.targetUIDs, newUIDs.count == confirmed.count {
                action.targetUIDs = newUIDs
                action.targetUIDValidity = moved.targetUIDValidity ?? 0
                action.isUndoable = true
            } else {
                action.isUndoable = false
            }
        } else {
            action.isUndoable = true
        }
    }

    private func isStopped(_ token: Int) -> Bool { Task.isCancelled || token != generation }

    private func checkStopped(_ token: Int) throws {
        if isStopped(token) { throw CancellationError() }
    }

    /// Flags the affected headers and adjusts the sender's profile row. Fetches
    /// by UID in chunks rather than loading the whole account.
    /// The facts the guard needs, fetched by UID in chunks.
    private func facts(for uids: [UInt32], in account: MailAccount) -> [SweepGuard.MessageFacts] {
        let accountID = account.id
        var out: [SweepGuard.MessageFacts] = []
        out.reserveCapacity(uids.count)
        for start in stride(from: 0, to: uids.count, by: 400) {
            let chunk = Array(uids[start..<min(start + 400, uids.count)])
            var descriptor = FetchDescriptor<MessageHeader>(predicate: #Predicate { $0.accountID == accountID && chunk.contains($0.uid) })
            descriptor.propertiesToFetch = [\.uid, \.subject, \.isFlagged, \.importanceRaw, \.receivedAt]
            for message in (try? modelContext.fetch(descriptor)) ?? [] {
                out.append(.init(uid: message.uid, subject: message.subject, isFlagged: message.isFlagged,
                                 importance: message.importance, receivedAt: message.receivedAt))
            }
        }
        return out
    }

    private func markSwept(uids: [UInt32], in account: MailAccount, swept: Bool, address: String) {
        let accountID = account.id
        for start in stride(from: 0, to: uids.count, by: 400) {
            let chunk = Array(uids[start..<min(start + 400, uids.count)])
            let descriptor = FetchDescriptor<MessageHeader>(
                predicate: #Predicate { $0.accountID == accountID && chunk.contains($0.uid) }
            )
            for message in (try? modelContext.fetch(descriptor)) ?? [] {
                message.isSweptLocally = swept
            }
        }
        SenderProfileBuilder.adjust(accountID: accountID, address: address, uids: uids, swept: swept, in: modelContext)
    }
}
