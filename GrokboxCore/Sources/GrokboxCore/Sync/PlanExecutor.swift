import Foundation
import SwiftData

/// The only thing in Grokbox that writes to a mailbox.
///
/// Every mutation is preceded by a `CleanupAction` record — written and saved
/// *before* the IMAP command goes out — so a crash mid-run still leaves an
/// accurate log, and undo always has something to read from.
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

    public private(set) var phase: Phase = .idle
    private var currentTask: Task<Void, Never>?
    private var activeProvider: (any MailProvider)?

    /// Stops a sweep or an undo in progress. Disconnecting is the part that
    /// matters: `Task.checkCancellation()` between senders can only be reached
    /// if the current IMAP command returns, and a wedged server never lets it.
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        if let provider = activeProvider {
            activeProvider = nil
            Task { await provider.finish() }
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
        let items = plan.enabledItems
        guard !items.isEmpty else { return }
        if recordRules {
            for item in items { RuleStore.set(.sweep, for: item.cluster.address, in: modelContext) }
        }

        phase = .connecting
        do {
            let provider = try await MailProviderFactory.connect(to: account)
            activeProvider = provider
            defer { activeProvider = nil; Task { await provider.finish() } }

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

            let keepTransactional = policy.guardTransactional
            var heldTotal = 0

            for item in items {
                try Task.checkCancellation()
                // Message-level safety net over the sender-level decision.
                _ = keepTransactional
                let verdict = guarded
                    ? SweepGuard.check(facts(for: item.cluster.pendingUIDs, in: account), policy: policy)
                    : SweepGuard.Verdict(allowed: item.cluster.pendingUIDs, held: [])
                let uids = verdict.allowed
                heldTotal += verdict.held.count
                guard !uids.isEmpty else { continue }

                if openMailbox != item.cluster.mailbox {
                    let status = try await provider.openReadWrite(item.cluster.mailbox)
                    try guardUIDValidity(status, account: account, mailbox: item.cluster.mailbox)
                    openMailbox = item.cluster.mailbox
                    openValidity = status.uidValidity ?? 0
                }

                if item.markRead {
                    let action = record(.markRead, for: item, uids: uids, account: account,  undoable: true, uidValidity: openValidity)
                    await run(action) {
                        try await provider.setFlags(uids: uids, .add, flags: ["\\Seen"])
                    }
                }

                if item.archive {
                    switch item.disposition {
                    case .trash:
                        // Deliberately a MOVE to the provider's Trash, never a
                        // \\Deleted flag and never EXPUNGE. The provider empties
                        // it on its own schedule; until then this is undoable.
                        let target = trashName ?? "Trash"
                        let action = record(.trash, for: item, uids: uids, account: account, labelName: target, undoable: false, uidValidity: openValidity)
                        action.heldUIDs = verdict.held.map(\.uid)
                        action.heldSummary = verdict.summary
                        action.targetMailbox = target
                        await run(action) {
                            let moved = try await provider.move(uids: uids, to: target)
                            if let newUIDs = moved.targetUIDs, newUIDs.count == uids.count {
                                action.targetUIDs = newUIDs
                                action.targetUIDValidity = moved.targetUIDValidity ?? 0
                                action.isUndoable = true
                            }
                        }
                        if action.errorMessage == nil { markSwept(uids: uids, in: account, swept: true, address: item.cluster.address) }

                    case .archiveOnly where isGmail:
                        let archive = record(.archive, for: item, uids: uids, account: account, undoable: true, uidValidity: openValidity)
                        archive.heldUIDs = verdict.held.map(\.uid)
                        archive.heldSummary = verdict.summary
                        await run(archive) {
                            try await provider.setGmailLabels(uids: uids, .remove, labels: ["\\Inbox"])
                        }
                        if archive.errorMessage == nil { markSwept(uids: uids, in: account, swept: true, address: item.cluster.address) }

                    case .archiveOnly:
                        let target = archiveName ?? "Archive"
                        let archive = record(.archive, for: item, uids: uids, account: account, labelName: target, undoable: false, uidValidity: openValidity)
                        archive.heldUIDs = verdict.held.map(\.uid)
                        archive.heldSummary = verdict.summary
                        archive.targetMailbox = target
                        await run(archive) {
                            let moved = try await provider.move(uids: uids, to: target)
                            if let newUIDs = moved.targetUIDs, newUIDs.count == uids.count {
                                archive.targetUIDs = newUIDs
                                archive.targetUIDValidity = moved.targetUIDValidity ?? 0
                                archive.isUndoable = true
                            }
                        }
                        if archive.errorMessage == nil { markSwept(uids: uids, in: account, swept: true, address: item.cluster.address) }

                    case .fileIntoFolders where isGmail:
                        let label = record(.label, for: item, uids: uids, account: account, labelName: item.folder, undoable: true, uidValidity: openValidity)
                        await run(label) {
                            try await provider.setGmailLabels(uids: uids, .add, labels: [item.folder])
                        }
                        let archive = record(.archive, for: item, uids: uids, account: account, undoable: true, uidValidity: openValidity)
                        archive.heldUIDs = verdict.held.map(\.uid)
                        archive.heldSummary = verdict.summary
                        await run(archive) {
                            try await provider.setGmailLabels(uids: uids, .remove, labels: ["\\Inbox"])
                        }
                        if archive.errorMessage == nil { markSwept(uids: uids, in: account, swept: true, address: item.cluster.address) }

                    case .fileIntoFolders:
                        // MOVE gives the messages new UIDs in the target. Servers with
                        // UIDPLUS report them (COPYUID), and that is what makes the
                        // move undoable; without it the action is recorded as final.
                        let target = serverFolder[item.folder] ?? item.folder
                        let archive = record(.archive, for: item, uids: uids, account: account, labelName: item.folder, undoable: false, uidValidity: openValidity)
                        archive.heldUIDs = verdict.held.map(\.uid)
                        archive.heldSummary = verdict.summary
                        archive.targetMailbox = target
                        await run(archive) {
                            let moved = try await provider.move(uids: uids, to: target)
                            if let newUIDs = moved.targetUIDs, newUIDs.count == uids.count {
                                archive.targetUIDs = newUIDs
                                archive.targetUIDValidity = moved.targetUIDValidity ?? 0
                                archive.isUndoable = true
                            }
                        }
                        if archive.errorMessage == nil { markSwept(uids: uids, in: account, swept: true, address: item.cluster.address) }
                    }
                }

                // The unsubscribe goes last, and only if the sweep itself
                // worked: telling a sender to stop is not undoable, so it must
                // never happen for mail that is still sitting in the inbox.
                if item.unsubscribe, unsubscribed.insert(item.cluster.address).inserted {
                    let action = record(.unsubscribe, for: item, uids: [], account: account,
                                        labelName: item.cluster.address, undoable: false, uidValidity: 0)
                    let outcome = await UnsubscribeService.unsubscribe(from: item.cluster)
                    switch outcome {
                    case .unsubscribed:
                        unsubscribeCount += 1
                    case .openInBrowser, .requiresEmail:
                        // Automatic mode is one-click only. Anything needing a
                        // browser or an email is left for the user to decide.
                        action.errorMessage = "Needs a browser; left for you in Senders."
                    case .failed(let why):
                        action.errorMessage = why
                    }
                }

                done += 1
                touched += uids.count
                phase = .applying(done: done, total: items.count)
                try modelContext.save()
            }

            RuleStore.bumpApplied(for: items.map(\.cluster.address), in: modelContext)
            let heldNote = heldTotal > 0 ? ", held \(heldTotal) for you" : ""
            let unsubNote = unsubscribeCount > 0 ? ", unsubscribed from \(unsubscribeCount)" : ""
            phase = .finished("Swept \(touched.formatted()) messages from \(done) senders\(heldNote)\(unsubNote)")
        } catch is CancellationError {
            try? modelContext.save()
            phase = .idle
        } catch {
            try? modelContext.save()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Archives one message from the Brief. Does not write a sender rule — a
    /// single "done" is not a decision about the sender.
    public func sweep(_ message: MessageHeader, in account: MailAccount) async {
        let cluster = SenderCluster(
            address: message.senderAddress, displayName: message.senderName.isEmpty ? message.senderAddress : message.senderName,
            domain: message.senderDomain, mailbox: message.mailbox,
            uids: [message.uid], unreadUIDs: message.isUnread ? [message.uid] : [],
            messageCount: 1, unreadCount: message.isUnread ? 1 : 0, flaggedCount: 0, sweptCount: 0,
            newest: message.receivedAt, oldest: message.receivedAt,
            hasUnsubscribeLink: false, unsubscribeValue: nil, supportsOneClickUnsubscribe: false,
            everContacted: false, sampleSubjects: [message.subject]
        )
        await apply(CleanupPlan(items: [.init(cluster: cluster)]), to: account, recordRules: false, guarded: false)
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
        undoable: Bool,
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
            isUndoable: undoable,
            uidValidity: uidValidity
        )
        modelContext.insert(action)
        try? modelContext.save()
        return action
    }

    private func run(_ action: CleanupAction, _ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            action.errorMessage = error.localizedDescription
            action.isUndoable = false
        }
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
